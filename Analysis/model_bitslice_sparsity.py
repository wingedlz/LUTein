# 
# Yolov3:
# python model_bitslice_sparsity.py --model yolov3 --image_dir ../../coco_val/val2017 --max_images 200 --img_size 640 --batch_size 8 --out_dir . --yolov3_repo_dir .\yolov3_repo --yolov3_weight_path .\yolov3_repo\yolov3.pt
# ResNet18:
# python model_bitslice_sparsity.py --model resnet18 --image_dir ../../coco_val/val2017 --max_images 200 --img_size 224 --batch_size 4 --out_dir .
# Vit:
# python model_bitslice_sparsity.py --model vit_b_16 --image_dir ../../coco_val/val2017 --max_images 200 --img_size 224 --batch_size 8 --out_dir .


import os
import sys
import glob
import argparse
from pathlib import Path
from collections import defaultdict

import pandas as pd
import torch
import torch.nn as nn
import matplotlib.pyplot as plt

from PIL import Image
from tqdm import tqdm
from torchvision import transforms
from torch.utils.data import Dataset, DataLoader
from torchvision.models import (
    resnet18,
    ResNet18_Weights,
    vit_b_16,
    ViT_B_16_Weights,
)


IMG_EXTS = {".jpg", ".jpeg", ".png", ".bmp", ".tif", ".tiff", ".webp"}


def list_images(image_dir):
    paths = []
    for ext in IMG_EXTS:
        paths.extend(glob.glob(os.path.join(image_dir, f"**/*{ext}"), recursive=True))
        paths.extend(glob.glob(os.path.join(image_dir, f"**/*{ext.upper()}"), recursive=True))
    return sorted(list(set(paths)))


def build_transform(model_name, img_size):
    if model_name in ["resnet18", "vit_b_16"]:
        if img_size <= 0:
            img_size = 224
        return transforms.Compose([
            transforms.Resize((img_size, img_size)),
            transforms.ToTensor(),
            transforms.Normalize(mean=[0.485, 0.456, 0.406],
                                 std=[0.229, 0.224, 0.225]),
        ])

    if model_name == "yolov3":
        if img_size <= 0:
            img_size = 640
        return transforms.Compose([
            transforms.Resize((img_size, img_size)),
            transforms.ToTensor(),
        ])

    raise ValueError(f"Unsupported model: {model_name}")


class ImageFolderFlat(Dataset):
    def __init__(self, image_paths, transform):
        self.image_paths = image_paths
        self.transform = transform

    def __len__(self):
        return len(self.image_paths)

    def __getitem__(self, idx):
        path = self.image_paths[idx]
        img = Image.open(path).convert("RGB")
        x = self.transform(img)
        return x, path


def quantize_int8_symmetric_per_tensor(x: torch.Tensor):
    x = x.detach()
    max_abs = x.abs().max()
    if max_abs == 0:
        scale = torch.tensor(1.0, device=x.device, dtype=x.dtype)
        q = torch.zeros_like(x, dtype=torch.int8)
        return q, scale
    scale = max_abs / 127.0
    q = torch.clamp(torch.round(x / scale), -128, 127).to(torch.int8)
    return q, scale


def quantize_int8_symmetric_per_out_channel(w: torch.Tensor):
    """
    Supports:
    - Conv2d weight: [out_channels, in_channels, kH, kW]
    - Linear weight: [out_features, in_features]
    """
    w = w.detach()
    out_ch = w.shape[0]
    q = torch.empty_like(w, dtype=torch.int8)
    scales = torch.empty(out_ch, device=w.device, dtype=w.dtype)

    for oc in range(out_ch):
        wc = w[oc]
        max_abs = wc.abs().max()
        if max_abs == 0:
            scales[oc] = 1.0
            q[oc] = torch.zeros_like(wc, dtype=torch.int8)
        else:
            scale = max_abs / 127.0
            scales[oc] = scale
            q[oc] = torch.clamp(torch.round(wc / scale), -128, 127).to(torch.int8)

    return q, scales


def int8_to_msb_lsb_nibbles(q: torch.Tensor):
    q_u8 = q.view(torch.uint8)
    lsb = q_u8 & 0x0F
    msb = (q_u8 >> 4) & 0x0F
    return msb, lsb


def nibble_zero_ratio(q: torch.Tensor):
    msb, lsb = int8_to_msb_lsb_nibbles(q)
    msb_zero = (msb == 0).float().mean().item()
    lsb_zero = (lsb == 0).float().mean().item()
    return msb_zero, lsb_zero


def tensor_zero_ratio(q: torch.Tensor):
    return (q == 0).float().mean().item()


def get_target_layers(model, model_name):
    layers = []

    if model_name in ["resnet18", "yolov3"]:
        target_type = nn.Conv2d
    elif model_name == "vit_b_16":
        target_type = nn.Linear
    else:
        raise ValueError(f"Unsupported model: {model_name}")

    for name, module in model.named_modules():
        if isinstance(module, target_type):
            layers.append((name, module))

    return layers


def summarize_weight_sparsity(target_layers):
    rows = []
    for layer_idx, (name, layer) in enumerate(target_layers):
        w = layer.weight.data
        q_w, _ = quantize_int8_symmetric_per_out_channel(w)
        msb_zero, lsb_zero = nibble_zero_ratio(q_w)
        int8_zero = tensor_zero_ratio(q_w)

        rows.append({
            "layer_idx": layer_idx,
            "layer_name": name,
            "kind": "weight",
            "tensor_zero_ratio": int8_zero,
            "msb_zero_ratio": msb_zero,
            "lsb_zero_ratio": lsb_zero,
            "numel": int(q_w.numel()),
            "shape": str(tuple(q_w.shape)),
        })
    return pd.DataFrame(rows)


class ActivationCollector:
    def __init__(self):
        self.stats = defaultdict(lambda: {
            "count": 0,
            "sum_tensor_zero_ratio": 0.0,
            "sum_msb_zero_ratio": 0.0,
            "sum_lsb_zero_ratio": 0.0,
            "numel": 0,
        })
        self.handles = []

    def add_hook(self, name, module):
        def hook_fn(mod, inputs, output):
            x = inputs[0].detach()
            q_x, _ = quantize_int8_symmetric_per_tensor(x)
            msb_zero, lsb_zero = nibble_zero_ratio(q_x)
            int8_zero = tensor_zero_ratio(q_x)

            self.stats[name]["count"] += 1
            self.stats[name]["sum_tensor_zero_ratio"] += int8_zero
            self.stats[name]["sum_msb_zero_ratio"] += msb_zero
            self.stats[name]["sum_lsb_zero_ratio"] += lsb_zero
            self.stats[name]["numel"] += q_x.numel()

        handle = module.register_forward_hook(hook_fn)
        self.handles.append(handle)

    def remove(self):
        for h in self.handles:
            h.remove()
        self.handles = []

    def to_dataframe(self, layer_name_to_idx):
        rows = []
        for name, d in self.stats.items():
            c = max(d["count"], 1)
            rows.append({
                "layer_idx": layer_name_to_idx[name],
                "layer_name": name,
                "kind": "input_activation",
                "tensor_zero_ratio": d["sum_tensor_zero_ratio"] / c,
                "msb_zero_ratio": d["sum_msb_zero_ratio"] / c,
                "lsb_zero_ratio": d["sum_lsb_zero_ratio"] / c,
                "num_forwards": d["count"],
                "total_numel_seen": int(d["numel"]),
            })
        df = pd.DataFrame(rows)
        return df.sort_values("layer_idx").reset_index(drop=True)


@torch.no_grad()
def run_activation_analysis(model, target_layers, dataloader, device, max_batches=None):
    collector = ActivationCollector()
    layer_name_to_idx = {name: idx for idx, (name, _) in enumerate(target_layers)}

    for name, module in target_layers:
        collector.add_hook(name, module)

    try:
        for batch_idx, (images, paths) in enumerate(tqdm(dataloader, desc="Running forward")):
            if max_batches is not None and batch_idx >= max_batches:
                break
            images = images.to(device, non_blocking=True)
            _ = model(images)
    finally:
        collector.remove()

    return collector.to_dataframe(layer_name_to_idx)


def plot_two_curves(df, title, save_path, layer_type_name):
    x = df["layer_idx"].values
    y_msb = df["msb_zero_ratio"].values * 100.0
    y_lsb = df["lsb_zero_ratio"].values * 100.0

    plt.figure(figsize=(12, 5))
    plt.plot(x, y_msb, label="MSB slice zero ratio (%)")
    plt.plot(x, y_lsb, label="LSB slice zero ratio (%)")
    plt.xlabel(f"{layer_type_name} layer index")
    plt.ylabel("Sparsity (%)")
    plt.title(title)
    plt.ylim(0, 100)
    plt.grid(True, alpha=0.3)
    plt.legend()
    plt.tight_layout()
    plt.savefig(save_path, dpi=200)
    plt.close()


def plot_combined(model_name, weight_df, act_df, save_path, layer_type_name):
    plt.figure(figsize=(12, 10))

    plt.subplot(2, 1, 1)
    plt.plot(weight_df["layer_idx"], weight_df["msb_zero_ratio"] * 100.0, label="MSB")
    plt.plot(weight_df["layer_idx"], weight_df["lsb_zero_ratio"] * 100.0, label="LSB")
    plt.title(f"{model_name} weight 8-bit -> 4-bit slice sparsity")
    plt.ylabel("Sparsity (%)")
    plt.ylim(0, 100)
    plt.grid(True, alpha=0.3)
    plt.legend()

    plt.subplot(2, 1, 2)
    plt.plot(act_df["layer_idx"], act_df["msb_zero_ratio"] * 100.0, label="MSB")
    plt.plot(act_df["layer_idx"], act_df["lsb_zero_ratio"] * 100.0, label="LSB")
    plt.title(f"{model_name} input activation 8-bit -> 4-bit slice sparsity")
    plt.xlabel(f"{layer_type_name} layer index")
    plt.ylabel("Sparsity (%)")
    plt.ylim(0, 100)
    plt.grid(True, alpha=0.3)
    plt.legend()

    plt.tight_layout()
    plt.savefig(save_path, dpi=200)
    plt.close()


def save_summary(weight_df, act_df, out_dir, model_name, layer_type_name):
    summary_rows = []

    for tag, df in [("weight", weight_df), ("input_activation", act_df)]:
        summary_rows.append({
            "model": model_name,
            "layer_type": layer_type_name,
            "kind": tag,
            "mean_tensor_zero_ratio": df["tensor_zero_ratio"].mean(),
            "mean_msb_zero_ratio": df["msb_zero_ratio"].mean(),
            "mean_lsb_zero_ratio": df["lsb_zero_ratio"].mean(),
            "min_msb_zero_ratio": df["msb_zero_ratio"].min(),
            "max_msb_zero_ratio": df["msb_zero_ratio"].max(),
            "min_lsb_zero_ratio": df["lsb_zero_ratio"].min(),
            "max_lsb_zero_ratio": df["lsb_zero_ratio"].max(),
            "num_layers": len(df),
        })

    summary_df = pd.DataFrame(summary_rows)
    summary_df.to_csv(os.path.join(out_dir, f"{model_name}_summary.csv"), index=False)


def load_resnet18(device):
    weights = ResNet18_Weights.IMAGENET1K_V1
    model = resnet18(weights=weights)
    model = model.to(device)
    model.eval()
    return model


def load_vit_b_16(device):
    weights = ViT_B_16_Weights.IMAGENET1K_V1
    model = vit_b_16(weights=weights)
    model = model.to(device)
    model.eval()
    return model


def load_yolov3_local(device, repo_dir, weight_path):
    """
    Load YOLOv3 from a local Ultralytics YOLOv3 repo and a local yolov3.pt.
    """
    repo_dir = Path(repo_dir).resolve()
    weight_path = Path(weight_path).resolve()

    if not repo_dir.exists():
        raise FileNotFoundError(f"YOLOv3 repo not found: {repo_dir}")
    if not (repo_dir / "models").exists():
        raise FileNotFoundError(f"'models' directory not found in repo: {repo_dir}")
    if not weight_path.exists():
        raise FileNotFoundError(f"YOLOv3 weight file not found: {weight_path}")

    sys.path.insert(0, str(repo_dir))
    from models.yolo import Model

    ckpt = torch.load(weight_path, map_location=device, weights_only=False)

    if isinstance(ckpt, dict) and "model" in ckpt:
        model = ckpt["model"]
        if hasattr(model, "float"):
            model = model.float()
    else:
        yaml_path = repo_dir / "models" / "yolov3.yaml"
        model = Model(str(yaml_path))
        state_dict = ckpt["state_dict"] if isinstance(ckpt, dict) and "state_dict" in ckpt else ckpt
        model.load_state_dict(state_dict, strict=False)

    model = model.to(device)
    model.eval()
    return model


def load_model(device, model_name, yolov3_repo_dir=None, yolov3_weight_path=None):
    if model_name == "resnet18":
        return load_resnet18(device)

    if model_name == "vit_b_16":
        return load_vit_b_16(device)

    if model_name == "yolov3":
        if yolov3_repo_dir is None or yolov3_weight_path is None:
            raise ValueError("YOLOv3 requires --yolov3_repo_dir and --yolov3_weight_path")
        return load_yolov3_local(device, yolov3_repo_dir, yolov3_weight_path)

    raise ValueError(f"Unsupported model: {model_name}")


def get_layer_type_name(model_name):
    if model_name in ["resnet18", "yolov3"]:
        return "Conv2d"
    if model_name == "vit_b_16":
        return "Linear"
    raise ValueError(f"Unsupported model: {model_name}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=str, default="resnet18", choices=["resnet18", "yolov3", "vit_b_16"])
    parser.add_argument("--image_dir", type=str, required=True)
    parser.add_argument("--out_dir", type=str, default="./bitslice_result")
    parser.add_argument("--max_images", type=int, default=1000)
    parser.add_argument("--img_size", type=int, default=0)
    parser.add_argument("--batch_size", type=int, default=8)
    parser.add_argument("--num_workers", type=int, default=4)
    parser.add_argument("--max_batches", type=int, default=None)

    parser.add_argument("--yolov3_repo_dir", type=str, default=None)
    parser.add_argument("--yolov3_weight_path", type=str, default=None)

    args = parser.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"Using device: {device}")

    image_paths = list_images(args.image_dir)
    if len(image_paths) == 0:
        raise RuntimeError(f"No images found in {args.image_dir}")

    image_paths = image_paths[:args.max_images]
    print(f"Found {len(image_paths)} images")

    transform = build_transform(args.model, args.img_size)
    dataset = ImageFolderFlat(image_paths, transform=transform)
    dataloader = DataLoader(
        dataset,
        batch_size=args.batch_size,
        shuffle=False,
        num_workers=args.num_workers,
        pin_memory=(device == "cuda"),
    )

    model = load_model(
        device=device,
        model_name=args.model,
        yolov3_repo_dir=args.yolov3_repo_dir,
        yolov3_weight_path=args.yolov3_weight_path,
    )

    target_layers = get_target_layers(model, args.model)
    layer_type_name = get_layer_type_name(args.model)

    print(f"Number of {layer_type_name} layers found: {len(target_layers)}")

    weight_df = summarize_weight_sparsity(target_layers)
    weight_csv = os.path.join(args.out_dir, f"{args.model}_weight_bitslice_sparsity.csv")
    weight_df.to_csv(weight_csv, index=False)

    act_df = run_activation_analysis(
        model=model,
        target_layers=target_layers,
        dataloader=dataloader,
        device=device,
        max_batches=args.max_batches,
    )
    act_csv = os.path.join(args.out_dir, f"{args.model}_input_activation_bitslice_sparsity.csv")
    act_df.to_csv(act_csv, index=False)

    merged_df = pd.merge(
        weight_df[["layer_idx", "layer_name", "tensor_zero_ratio", "msb_zero_ratio", "lsb_zero_ratio"]],
        act_df[["layer_idx", "layer_name", "tensor_zero_ratio", "msb_zero_ratio", "lsb_zero_ratio"]],
        on=["layer_idx", "layer_name"],
        suffixes=("_weight", "_input"),
    )
    merged_csv = os.path.join(args.out_dir, f"{args.model}_merged_bitslice_sparsity.csv")
    merged_df.to_csv(merged_csv, index=False)

    weight_png = os.path.join(args.out_dir, f"{args.model}_weight_bitslice_sparsity.png")
    act_png = os.path.join(args.out_dir, f"{args.model}_input_activation_bitslice_sparsity.png")
    combined_png = os.path.join(args.out_dir, f"{args.model}_combined_bitslice_sparsity.png")

    plot_two_curves(
        weight_df.sort_values("layer_idx"),
        f"{args.model} weight 8-bit -> 4-bit slice sparsity",
        weight_png,
        layer_type_name,
    )
    plot_two_curves(
        act_df.sort_values("layer_idx"),
        f"{args.model} input activation 8-bit -> 4-bit slice sparsity",
        act_png,
        layer_type_name,
    )
    plot_combined(
        args.model,
        weight_df.sort_values("layer_idx"),
        act_df.sort_values("layer_idx"),
        combined_png,
        layer_type_name,
    )

    save_summary(weight_df, act_df, args.out_dir, args.model, layer_type_name)

    print("Saved files:")
    print(weight_csv)
    print(act_csv)
    print(merged_csv)
    print(os.path.join(args.out_dir, f"{args.model}_summary.csv"))
    print(weight_png)
    print(act_png)
    print(combined_png)


if __name__ == "__main__":
    main()