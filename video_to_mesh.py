import os
import cv2
import numpy as np
import torch
from tqdm import tqdm
from pathlib import Path

from hamer.models import load_hamer  # loads model + cfg
#from hamer.models.renderers import Renderer


def sample_video_frames(video_path, fps_sample=2):
    """Sample frames from a video at `fps_sample` frames per second."""
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise ValueError(f"Cannot open video: {video_path}")

    fps = cap.get(cv2.CAP_PROP_FPS)
    interval = int(round(fps / fps_sample))
    frames = []
    frame_indices = []

    idx = 0
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        if idx % interval == 0:
            frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            frames.append(frame_rgb)
            frame_indices.append(idx)
        idx += 1

    cap.release()
    return frames, frame_indices


def run_hamer_on_video(video_path, output_dir="results", fps_sample=2, device="cuda"):
    """
    Sample frames from a video, run HaMeR, and save meshes as .npz.
    Output: npz with vertices, faces, and camera params.
    """
    os.makedirs(output_dir, exist_ok=True)
    video_name = Path(video_path).stem
    out_path = os.path.join(output_dir, f"{video_name}_meshes.npz")

    print(f"Sampling frames from {video_path} at {fps_sample} fps...")
    frames, frame_indices = sample_video_frames(video_path, fps_sample)
    print(f"{len(frames)} frames sampled.")

    # Load pretrained HaMeR model
    print("Loading HaMeR model...")
    checkpoint_path = "./_DATA/hamer_ckpts/checkpoints/hamer.ckpt"
    model, model_cfg = load_hamer(checkpoint_path)
    model = model.to(device)
    model.eval()

    all_vertices, all_cameras = [], []
    faces = model.mano.faces  # static MANO topology

    print("Running inference...")
    with torch.no_grad():
        for frame in tqdm(frames):
            # Resize to the expected input size (224x224)
            resized = cv2.resize(frame, (256, 256))
            img = torch.from_numpy(resized).permute(2, 0, 1).float() / 255.0
            img = img.unsqueeze(0).to(device)


            batch = {"img": img}
            out = model(batch)
            # Handle both output formats
            if "vertices" in out:
                verts = out["vertices"].detach().cpu().numpy()[0]
            else:
                verts = out["pred_vertices"].detach().cpu().numpy()[0]

            cam = out["pred_cam"].detach().cpu().numpy()[0]

            cam = out["pred_cam"].detach().cpu().numpy()[0]


            all_vertices.append(verts)
            all_cameras.append(cam)

    np.savez_compressed(
        out_path,
        vertices=np.array(all_vertices, dtype=np.float32),
        faces=np.array(faces, dtype=np.int32),
        cameras=np.array(all_cameras, dtype=np.float32),
        frame_indices=np.array(frame_indices, dtype=np.int32),
    )

    print(f"Saved meshes for {len(frames)} frames to {out_path}")
    return out_path


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--video_path", required=True, help="Path to input video file")
    parser.add_argument("--output_dir", default="results", help="Where to save .npz file")
    parser.add_argument("--fps_sample", type=int, default=2, help="Frames per second to sample")
    parser.add_argument("--device", default="cuda", help="cuda or cpu")
    args = parser.parse_args()

    run_hamer_on_video(
        args.video_path,
        output_dir=args.output_dir,
        fps_sample=args.fps_sample,
        device=args.device,
    )
