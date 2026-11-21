#!/usr/bin/env python3
"""Assemble finetune_qwen35_decillion.ipynb from cells/*.md and cells/*.py (in name order)."""
import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
cells = []
for name in sorted(os.listdir(os.path.join(HERE, 'cells'))):
    src = open(os.path.join(HERE, 'cells', name), encoding='utf-8').read().rstrip('\n')
    lines = [l + '\n' for l in src.split('\n')]
    lines[-1] = lines[-1].rstrip('\n')
    if name.endswith('.md'):
        cells.append({'cell_type': 'markdown', 'metadata': {}, 'source': lines})
    else:
        cells.append({'cell_type': 'code', 'metadata': {}, 'execution_count': None, 'outputs': [], 'source': lines})
nb = {'nbformat': 4, 'nbformat_minor': 5, 'cells': cells,
      'metadata': {'accelerator': 'GPU', 'colab': {'gpuType': 'L4', 'provenance': []},
                   'kernelspec': {'name': 'python3', 'display_name': 'Python 3'}, 'language_info': {'name': 'python'}}}
json.dump(nb, open(os.path.join(HERE, 'finetune_qwen35_decillion.ipynb'), 'w', encoding='utf-8'), indent=1, ensure_ascii=False)
print(len(cells), 'cells')
