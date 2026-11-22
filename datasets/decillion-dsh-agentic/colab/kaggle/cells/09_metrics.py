# 9. Training status and held-out validation metrics
import json, os
path = f'{OUT_DIR}/train_status.json'
if not os.path.exists(path):
    raise RuntimeError('no train_status.json: check the output of cell 8')
status = json.load(open(path))
print('complete:', status['complete'], f'| step {status["global_step"]}/{status["max_steps"]}',
      f'| {status["hours_this_session"]} h this session')
print('eval:', json.dumps(status['eval'], indent=1))
losses = [(h['step'], round(h['loss'], 4)) for h in status['log_history'] if 'loss' in h]
evals = [(h['step'], round(h['eval_loss'], 4)) for h in status['log_history'] if 'eval_loss' in h]
print('train loss (step, loss):', losses[-12:])
print('eval loss  (step, loss):', evals)
if not status['complete']:
    print('Training is not finished: save this version (or let it push to the Hub) and rerun the notebook to resume. '
          'You can still merge the partial adapter in cell 10 to try it.')
