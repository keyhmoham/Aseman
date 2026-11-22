# 4. Get the dataset generator from GitHub and build the training rows (about 3 minutes).
import os
if not os.path.exists(REPO_DIR):
    !git clone -q --depth 1 -b {BRANCH} {REPO} {REPO_DIR}
else:
    !git -C {REPO_DIR} pull -q --ff-only
!python3 {DATA_DIR}/scripts/build.py --tools {TOOLS_MODE} --out {DIST_DIR}
!ls -la {DIST_DIR}
