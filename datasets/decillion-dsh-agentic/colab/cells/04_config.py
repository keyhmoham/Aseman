# 4. Configuration (the only cell you normally edit)
MODEL_ID = 'Qwen/Qwen3.5-4B'
REPO = 'https://github.com/keyhmoham/Aseman.git'
BRANCH = 'main'
DATA_DIR = '/content/Aseman/datasets/decillion-dsh-agentic'

BIG_GPU = GPU_MEM_GB >= 35
MAX_SEQ_LEN = 16384 if BIG_GPU else 8192
LOAD_IN_4BIT = not BIG_GPU

# LoRA
LORA_R, LORA_ALPHA, LORA_DROPOUT = 32, 32, 0.0

# Training
EPOCHS = 1
LEARNING_RATE = 1e-4
BATCH_SIZE = 2 if BIG_GPU else 1
GRAD_ACCUM = 8 if BIG_GPU else 16
WARMUP_RATIO = 0.03
SAVE_STEPS = 200

# Data mix: multi-turn sessions are ~94% of the data; single-turn families are repeated to balance it
SINGLE_TURN_REPEAT = 4
MAX_MULTI_TURN = 30000   # cap on session.* rows per epoch (None = all ~64k)
TOOLS_MODE = 'relevant'  # 'relevant' (default) or 'full' (all ~130 tool schemas per row; needs long context)
SEED = 3407

print(dict(MODEL_ID=MODEL_ID, MAX_SEQ_LEN=MAX_SEQ_LEN, LOAD_IN_4BIT=LOAD_IN_4BIT, BATCH=BATCH_SIZE, ACCUM=GRAD_ACCUM))
