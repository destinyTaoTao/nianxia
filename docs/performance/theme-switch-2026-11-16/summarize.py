#!/usr/bin/env python3
"""Summarize captured frame windows; never interpret counts as physical FPS."""
import json
import math
import sys
from pathlib import Path


def summarize(data):
    budget = 1_000_000 / data['refreshRate']

    def p95_ms(values):
        return round(sorted(values)[math.ceil(len(values) * .95) - 1] / 1000, 3)

    def group(samples):
        frames = [frame for sample in samples for frame in sample['frames']]
        over = sum(f['buildUs'] > budget or f['rasterUs'] > budget for f in frames)
        return {
            'samples': len(samples),
            'canvasFramework_p95_ms': p95_ms([s['canvasUs'] for s in samples]),
            'brightnessFramework_p95_ms': p95_ms([s['brightnessUs'] for s in samples]),
            'frames': len(frames),
            'build_p95_ms': p95_ms([f['buildUs'] for f in frames]),
            'raster_p95_ms': p95_ms([f['rasterUs'] for f in frames]),
            'overBudgetFrames': over,
            'overBudgetPercent': round(100 * over / len(frames), 2),
        }

    return {
        'runId': data['runId'],
        'scheduler': data['scheduler'],
        'idleFrames': data['idleFrames'],
        'refreshRate': data['refreshRate'],
        'selection': {name: group(samples) for name, samples in [
            ('first', data['samples'][:1]), ('warm', data['samples'][1:]),
            ('all', data['samples'])]},
        'callbackControlWarm': group(data['callbackControl'][1:]),
        **({'sameChoiceControlWarm': group(data['sameChoiceControl'][1:])}
           if data.get('sameChoiceControl') else {}),
        'storage_p95_ms': p95_ms(data['storageOnlyUs']),
        'themePairFactory_p95_ms': p95_ms(data['themePairConstructionUs']),
    }


if __name__ == '__main__':
    print(json.dumps(summarize(json.loads(Path(sys.argv[1]).read_text())), indent=2))
