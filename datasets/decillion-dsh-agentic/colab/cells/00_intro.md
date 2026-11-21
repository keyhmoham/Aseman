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
11. Evaluate: validation loss and perplexity on the agent's turns (saved to Drive)
12. Save a merged 16-bit model to Drive (for serving) and free the GPU
13. Serve the merged model with vLLM: an OpenAI-compatible API on port 8000
14. Expose that API to the internet with a Cloudflare quick tunnel
15. Test the public API end to end and print the provider config for Decillion

Cells 13–15 need the GPU runtime and run after training. The quick tunnel URL is temporary: it lives
only while this runtime and `cloudflared` stay up, so rerun cells 13–14 (and update the provider in
Decillion) after a disconnect.
