# 3. Install (Unsloth brings matching torch / transformers / trl / peft versions)
!pip install -q -U unsloth unsloth_zoo
!pip install -q -U jsonschema
# If loading the model later fails on the Qwen3.5 architecture, run this and restart the runtime:
# !pip install -q -U transformers
