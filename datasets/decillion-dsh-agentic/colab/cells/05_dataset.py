# 5. Get the dataset from GitHub and build the training rows (about 3 minutes)
import os
if not os.path.exists(DATA_DIR):
    !git clone -q --depth 1 -b {BRANCH} {REPO} /content/Aseman
else:
    !git -C /content/Aseman pull -q
!python3 {DATA_DIR}/scripts/build.py --tools {TOOLS_MODE} --out /content/dist
!ls -la /content/dist
!cat /content/dist/stats.json | head -40
