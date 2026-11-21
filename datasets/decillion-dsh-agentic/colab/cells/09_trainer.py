# 9. Trainer: loss only on the assistant's turns (replies and tool calls), not on system, user or tool results
from trl import SFTTrainer, SFTConfig
from unsloth.chat_templates import train_on_responses_only
from unsloth import is_bfloat16_supported

args = SFTConfig(
    output_dir=f'{OUT_DIR}/checkpoints',
    dataset_text_field='text',
    packing=False,
    num_train_epochs=EPOCHS,
    per_device_train_batch_size=BATCH_SIZE,
    per_device_eval_batch_size=1,
    gradient_accumulation_steps=GRAD_ACCUM,
    learning_rate=LEARNING_RATE,
    lr_scheduler_type='cosine',
    warmup_ratio=WARMUP_RATIO,
    weight_decay=0.01,
    optim='adamw_8bit',
    bf16=is_bfloat16_supported(),
    fp16=not is_bfloat16_supported(),
    logging_steps=10,
    eval_strategy='steps',
    eval_steps=SAVE_STEPS,
    save_strategy='steps',
    save_steps=SAVE_STEPS,
    save_total_limit=3,
    report_to='none',
    seed=SEED,
)

trainer = SFTTrainer(
    model=model,
    tokenizer=tokenizer,
    train_dataset=train_ds,
    eval_dataset=val_ds.select(range(min(300, len(val_ds)))),
    args=args,
)
# Qwen chat format: tool results arrive inside user turns (<tool_response>), so masking every
# non-assistant turn leaves exactly the agent's own output in the loss.
trainer = train_on_responses_only(
    trainer,
    instruction_part='<|im_start|>user\n',
    response_part='<|im_start|>assistant\n',
)
print('steps per epoch ≈', len(train_ds) // (BATCH_SIZE * GRAD_ACCUM))
