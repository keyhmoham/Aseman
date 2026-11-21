# 11. Evaluate on the held-out validation split: loss and perplexity on the agent's own turns
import math, json as _json
metrics = trainer.evaluate(eval_dataset=val_ds)
metrics['eval_perplexity'] = math.exp(metrics['eval_loss'])
print(_json.dumps(metrics, indent=1))
_json.dump(metrics, open(f'{OUT_DIR}/eval_metrics.json', 'w'), indent=1)
