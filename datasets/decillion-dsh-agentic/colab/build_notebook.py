#!/usr/bin/env python3
"""Assemble the notebooks from their cell sources (one file per cell, in name order).

    python3 build_notebook.py            # both notebooks
    python3 build_notebook.py kaggle     # finetune_qwen35_kaggle.ipynb   from kaggle/cells (QLoRA, 2xT4)
    python3 build_notebook.py colab      # finetune_qwen35_decillion.ipynb from cells       (Unsloth, one GPU)

Cell files: *.md is a markdown cell, *.py a code cell, and *.writefile a %%writefile cell whose first line is the
target path and whose second line names a script next to the cells folder, inlined at build time. That keeps
the Kaggle notebook self-contained while the scripts stay real, testable files.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
TARGETS = {
    'kaggle': dict(cells='kaggle/cells', out='finetune_qwen35_kaggle.ipynb',
                   metadata={'kernelspec': {'name': 'python3', 'display_name': 'Python 3', 'language': 'python'},
                             'language_info': {'name': 'python'},
                             'kaggle': {'accelerator': 'nvidiaTeslaT4', 'isGpuEnabled': True,
                                        'isInternetEnabled': True, 'dataSources': []}}),
    'colab': dict(cells='cells', out='finetune_qwen35_decillion.ipynb',
                  metadata={'accelerator': 'GPU', 'colab': {'gpuType': 'L4', 'provenance': []},
                            'kernelspec': {'name': 'python3', 'display_name': 'Python 3'},
                            'language_info': {'name': 'python'}}),
}


def as_lines(src):
    lines = [l + '\n' for l in src.rstrip('\n').split('\n')]
    lines[-1] = lines[-1].rstrip('\n')
    return lines


def build(name):
    t = TARGETS[name]
    cell_dir = os.path.join(HERE, t['cells'])
    cells = []
    for fname in sorted(os.listdir(cell_dir)):
        path = os.path.join(cell_dir, fname)
        src = open(path, encoding='utf-8').read()
        if fname.endswith('.md'):
            cells.append({'cell_type': 'markdown', 'metadata': {}, 'source': as_lines(src)})
            continue
        if fname.endswith('.writefile'):
            target, script = src.split('\n')[:2]
            body = open(os.path.join(cell_dir, '..', script.strip()), encoding='utf-8').read()
            src = f'%%writefile {target.strip()}\n{body}'
        elif not fname.endswith('.py'):
            continue
        cells.append({'cell_type': 'code', 'metadata': {}, 'execution_count': None, 'outputs': [],
                      'source': as_lines(src)})
    nb = {'nbformat': 4, 'nbformat_minor': 5, 'cells': cells, 'metadata': t['metadata']}
    out = os.path.join(HERE, t['out'])
    json.dump(nb, open(out, 'w', encoding='utf-8'), indent=1, ensure_ascii=False)
    print(f'{t["out"]}: {len(cells)} cells')


if __name__ == '__main__':
    for name in (sys.argv[1:] or ['kaggle', 'colab']):
        build(name)
