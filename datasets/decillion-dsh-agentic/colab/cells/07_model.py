# 7. Load Qwen3.5-4B and attach LoRA adapters
from unsloth import FastLanguageModel
model, tokenizer = FastLanguageModel.from_pretrained(
    model_name=MODEL_ID,
    max_seq_length=MAX_SEQ_LEN,
    load_in_4bit=LOAD_IN_4BIT,
    dtype=None,
)
model = FastLanguageModel.get_peft_model(
    model,
    r=LORA_R, lora_alpha=LORA_ALPHA, lora_dropout=LORA_DROPOUT,
    target_modules=['q_proj', 'k_proj', 'v_proj', 'o_proj', 'gate_proj', 'up_proj', 'down_proj'],
    bias='none',
    use_gradient_checkpointing='unsloth',
    random_state=SEED,
)
model.print_trainable_parameters()
