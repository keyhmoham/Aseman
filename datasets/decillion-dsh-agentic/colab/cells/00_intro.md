# Fine-tune Qwen3.5-4B for the Decillion dsh agentic system

Run the cells in order (Runtime → Change runtime type → a GPU; A100/L4 recommended, T4 works with shorter context).

1. GPU check
2. Mount Google Drive (outputs go to `MyDrive/decillion-qwen35-4b`)
3. Install libraries
4. Configuration (the only cell you normally edit)
5. Clone the dataset from GitHub and build the training rows
6. Choose the training mix
7. Load Qwen3.5-4B with LoRA
8. Render rows with the model's chat template
9. Trainer with loss on the assistant's turns only
10. Train (checkpoints, including the LoRA adapter, are saved to Drive and resumed after a disconnect)
