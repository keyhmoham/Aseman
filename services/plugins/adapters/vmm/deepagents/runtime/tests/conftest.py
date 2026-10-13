import os
import sys
import tempfile
from pathlib import Path

# The sandbox of the tests is the local shell, so the space's workspace is a
# temporary directory (set before the runtime reads it).
ROOT = Path(tempfile.mkdtemp(prefix="tradera-agents-"))
os.environ["TRADERA_WORKSPACE"] = str(ROOT / "workspace")
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
