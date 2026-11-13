import { beforeEach, describe, expect, test } from 'bun:test';
import { buildStoredDiagnosis } from '@marklayer/agent-tools/diagnosis';
import { type CommentOp, diagnosisSchema } from '@marklayer/types/ops';
import { captureDiagnosis } from './diagnosis';

const comment: CommentOp = {
  id: 'c1',
  tool: 'comment',
  num: 1,
  text: 'cannot click',
  x: 20,
  y: 30,
  color: '#000',
  lineWidth: 2,
  ts: 1,
  target: { selector: '#target', tag: 'button', markdown: 'button: Save' },
};

describe('captureDiagnosis', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
  });

  test('captures a real target, overlay chain, current viewport and error buffers', () => {
    document.body.innerHTML = '<mark-layer></mark-layer><div id="cover"><button id="target">Save</button></div>';
    const target = document.querySelector('#target')!;
    const cover = document.querySelector('#cover')!;
    const overlay = document.querySelector('mark-layer')!;
    target.getBoundingClientRect = () => ({
      x: 10,
      y: 20,
      left: 10,
      top: 20,
      right: 30,
      bottom: 40,
      width: 20,
      height: 20,
      toJSON: () => ({}),
    });
    Object.defineProperty(document, 'elementsFromPoint', { configurable: true, value: () => [overlay, cover, target] });
    Object.defineProperty(document, 'elementFromPoint', { configurable: true, value: () => overlay });

    (target as HTMLElement).style.pointerEvents = 'none';
    const diagnosis = captureDiagnosis(comment, 100);
    const partial = buildStoredDiagnosis(comment, 100);
    expect(Object.keys(diagnosis).sort()).toEqual(Object.keys(partial).sort());
    expect(diagnosis.summary).toContain('targetPointerEvents: none');
    expect(diagnosis.summary!.length).toBeLessThanOrEqual(400);
    expect(partial.missing!.length).toBeGreaterThan(0);
    expect(partial.summary).toContain('证据不足');
    expect(partial.summary!.length).toBeLessThanOrEqual(400);
    expect(diagnosis.hitChain![0]).toMatchObject({
      selector: '#cover',
      isTarget: false,
      ariaHidden: false,
      inert: false,
    });
    expect(diagnosisSchema.safeParse(diagnosis).success).toBe(true);
    expect(diagnosis.source).toBe('live-page');
    expect(diagnosis.hitTest?.covered).toBe(true);
    expect(diagnosis.hitTest?.chain[0]).toMatchObject({ tag: 'div', selector: '#cover' });
    expect(diagnosis.target?.selector).toBe('#target');
    expect(diagnosis.viewport?.devicePixelRatio).toBeGreaterThan(0);
  });
});
