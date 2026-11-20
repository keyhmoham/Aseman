"""Entry point: `python server.py` (PORT, default 8787)."""
import logging
import os

import uvicorn

from peyda.api import create_app

logging.basicConfig(level=os.environ.get("PEYDA_LOG", "INFO"), format="%(asctime)s %(name)s %(levelname)s %(message)s")
app = create_app()

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8787")), log_level="warning")
