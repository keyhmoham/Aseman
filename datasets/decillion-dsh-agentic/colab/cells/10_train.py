# 10. Train (resumes from the last checkpoint on Drive if the runtime was disconnected)
import glob
last = sorted(glob.glob(f'{OUT_DIR}/checkpoints/checkpoint-*'), key=lambda p: int(p.rsplit('-', 1)[1]))
stats = trainer.train(resume_from_checkpoint=last[-1] if last else None)
print(stats)
