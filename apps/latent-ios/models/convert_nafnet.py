"""Converts the NAFNet SIDD denoising model (width 32) to Core ML for Silverbath's AI denoise.

The weights are megvii-research's NAFNet-SIDD-width32 (MIT License, https://github.com/megvii-research/NAFNet),
trained on the SIDD smartphone photos. The network below is written from the paper (Chen et al., "Simple Baselines
for Image Restoration", ECCV 2022); its module names follow the published checkpoint's, so the weights load with
strict checking. Run by .github/workflows/models.yml on a Mac:

    python3 convert_nafnet.py NAFNet-SIDD-width32.pth NAFNet-SIDD-w32.mlpackage

The package takes `image` (1 x 3 x 512 x 512, sRGB-encoded values 0..1) and gives `denoised` (the same shape). It
checks itself before it is written: on a noisy test picture the Core ML model must clean up most of the noise and
agree with PyTorch.
"""
import sys

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

TILE = 512


class LayerNorm2d(nn.Module):
    """Layer normalization over the channels of each pixel."""

    def __init__(self, channels, eps=1e-6):
        super().__init__()
        self.weight = nn.Parameter(torch.ones(channels))
        self.bias = nn.Parameter(torch.zeros(channels))
        self.eps = eps

    def forward(self, x):
        mu = x.mean(1, keepdim=True)
        var = (x - mu).pow(2).mean(1, keepdim=True)
        y = (x - mu) / torch.sqrt(var + self.eps)
        return self.weight.view(1, -1, 1, 1) * y + self.bias.view(1, -1, 1, 1)


class SimpleGate(nn.Module):
    """The paper's activation: split the channels in two halves and multiply them."""

    def forward(self, x):
        a, b = x.chunk(2, dim=1)
        return a * b


class NAFBlock(nn.Module):
    def __init__(self, c):
        super().__init__()
        dw = c * 2
        self.conv1 = nn.Conv2d(c, dw, 1)
        self.conv2 = nn.Conv2d(dw, dw, 3, padding=1, groups=dw)
        self.conv3 = nn.Conv2d(dw // 2, c, 1)
        # simplified channel attention
        self.sca = nn.Sequential(nn.AdaptiveAvgPool2d(1), nn.Conv2d(dw // 2, dw // 2, 1))
        self.sg = SimpleGate()
        ffn = c * 2
        self.conv4 = nn.Conv2d(c, ffn, 1)
        self.conv5 = nn.Conv2d(ffn // 2, c, 1)
        self.norm1 = LayerNorm2d(c)
        self.norm2 = LayerNorm2d(c)
        self.beta = nn.Parameter(torch.zeros(1, c, 1, 1))
        self.gamma = nn.Parameter(torch.zeros(1, c, 1, 1))

    def forward(self, inp):
        x = self.conv2(self.conv1(self.norm1(inp)))
        x = self.sg(x)
        x = x * self.sca(x)
        y = inp + self.conv3(x) * self.beta
        x = self.conv5(self.sg(self.conv4(self.norm2(y))))
        return y + x * self.gamma


class NAFNet(nn.Module):
    def __init__(self, width=32, enc=(2, 2, 4, 8), middle=12, dec=(2, 2, 2, 2)):
        super().__init__()
        self.intro = nn.Conv2d(3, width, 3, padding=1)
        self.ending = nn.Conv2d(width, 3, 3, padding=1)
        self.encoders, self.decoders, self.ups, self.downs = nn.ModuleList(), nn.ModuleList(), nn.ModuleList(), nn.ModuleList()
        chan = width
        for n in enc:
            self.encoders.append(nn.Sequential(*[NAFBlock(chan) for _ in range(n)]))
            self.downs.append(nn.Conv2d(chan, chan * 2, 2, 2))
            chan *= 2
        self.middle_blks = nn.Sequential(*[NAFBlock(chan) for _ in range(middle)])
        for n in dec:
            self.ups.append(nn.Sequential(nn.Conv2d(chan, chan * 2, 1, bias=False), nn.PixelShuffle(2)))
            chan //= 2
            self.decoders.append(nn.Sequential(*[NAFBlock(chan) for _ in range(n)]))

    def forward(self, inp):
        x = self.intro(inp)
        skips = []
        for encoder, down in zip(self.encoders, self.downs):
            x = encoder(x)
            skips.append(x)
            x = down(x)
        x = self.middle_blks(x)
        for decoder, up, skip in zip(self.decoders, self.ups, skips[::-1]):
            x = decoder(up(x) + skip)
        return self.ending(x) + inp


def psnr(a, b):
    return 10 * np.log10(1.0 / max(float(np.mean((a - b) ** 2)), 1e-12))


def main():
    import coremltools as ct

    weights, out = sys.argv[1], sys.argv[2]
    ckpt = torch.load(weights, map_location="cpu", weights_only=True)
    net = NAFNet()
    net.load_state_dict(ckpt.get("params", ckpt), strict=True)
    net.eval()

    example = torch.rand(1, 3, TILE, TILE)
    traced = torch.jit.trace(net, example)
    model = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.TensorType(name="image", shape=(1, 3, TILE, TILE), dtype=np.float32)],
        outputs=[ct.TensorType(name="denoised", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
    )
    model.short_description = "NAFNet SIDD width 32 (megvii-research, MIT License): denoises 512 x 512 sRGB tiles, values 0..1."
    model.license = "MIT"

    # a smooth test picture with sharp edges, and photo-like noise on it
    rng = np.random.default_rng(7)
    yy, xx = np.mgrid[0:TILE, 0:TILE] / TILE
    clean = np.stack([0.2 + 0.6 * xx, 0.3 + 0.4 * yy, 0.5 + 0.3 * np.sin(6 * xx) * (yy > 0.5)]).astype(np.float32)[None]
    noisy = np.clip(clean + rng.normal(0, 0.05, clean.shape).astype(np.float32), 0, 1)
    with torch.no_grad():
        ref = net(torch.from_numpy(noisy)).numpy()
    got = model.predict({"image": noisy})["denoised"]
    before, after_torch, after_coreml = psnr(noisy, clean), psnr(ref, clean), psnr(got, clean)
    agree = psnr(got, ref)
    print(f"PSNR noisy {before:.2f} dB, PyTorch {after_torch:.2f} dB, Core ML {after_coreml:.2f} dB; Core ML vs PyTorch {agree:.2f} dB")
    if after_coreml < before + 4 or agree < 30:
        sys.exit("the converted model does not clean the test picture well enough")
    model.save(out)


if __name__ == "__main__":
    main()
