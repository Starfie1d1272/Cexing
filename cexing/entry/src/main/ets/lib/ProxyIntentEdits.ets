import { EditIntent, EditOperation, EditTarget } from './ConfigEditor';
import { ProxyMappingDraft } from './ProxyMappingForm';

/** Local field-operation construction against the compiler's original target.
 * No YAML compilation, persistence, or guessed fingerprints occur here. */
export namespace ProxyIntentEdits {
  function copy(intent: EditIntent): EditIntent { return JSON.parse(JSON.stringify(intent)) as EditIntent; }

  export function shownTarget(target: EditTarget, intent: EditIntent, section: string): EditTarget {
    const shown = JSON.parse(JSON.stringify(target)) as EditTarget;
    const value = shown.value as Record<string, Object>;
    for (const op of intent.operations) {
      if (op.section !== section || op.target !== target.item.id) { continue; }
      if (op.kind === 'update') {
        for (const key of Object.keys(op.patch ?? {})) {
          if (key === '__proto__' || key === 'constructor' || key === 'prototype') { continue; }
          value[key] = op.patch![key];
        }
        for (const key of op.remove ?? []) { delete value[key]; }
      } else if (op.kind === 'rename') {
        shown.name = op.name;
        if (section !== 'proxy-providers') { value['name'] = op.name ?? ''; }
      }
    }
    return shown;
  }

  export function mapping(intent: EditIntent, original: EditTarget | null,
    draft: ProxyMappingDraft, action: string, missingFieldRevision: string): EditIntent {
    const next = copy(intent);
    if (original === null) {
      next.operations.push({ id: action, kind: 'add', section: draft.section,
        name: draft.name, value: draft.value });
      return next;
    }
    const id = original.item.id;
    next.operations = next.operations.filter((op: EditOperation) =>
      op.section !== draft.section || op.target !== id || (op.kind !== 'update' && op.kind !== 'rename'));
    const before = original.value as Record<string, Object>;
    const patch: Record<string, Object> = {};
    const conditions: Record<string, string> = {};
    const remove: string[] = [];
    const keys = Object.keys(before).concat(Object.keys(draft.value).filter((key: string) =>
      !Object.keys(before).includes(key)));
    for (const key of keys) {
      if (key === 'name' && draft.section !== 'proxy-providers') { continue; }
      if (JSON.stringify(before[key]) === JSON.stringify(draft.value[key])) { continue; }
      if (['__proto__', 'constructor', 'prototype'].includes(key)) { throw new Error('该字段请使用原始配置编辑'); }
      const fingerprint = original.item.fields?.[key] ?? missingFieldRevision;
      if (fingerprint.length === 0) { throw new Error('字段信息不足，请重新打开编辑'); }
      conditions[key] = fingerprint;
      if (!Object.keys(draft.value).includes(key)) { remove.push(key); }
      else { patch[key] = draft.value[key]; }
    }
    if (Object.keys(patch).length > 0 || remove.length > 0) {
      next.operations.push({ id: `${action}-fields`, kind: 'update', section: draft.section,
        target: id, patch: patch, remove: remove, preconditions: conditions });
    }
    const originalName = original.name ?? String(before['name'] ?? '');
    if (draft.name !== originalName) {
      next.operations.push({ id: `${action}-rename`, kind: 'rename', section: draft.section,
        target: id, expected: original.item.revision, name: draft.name });
    }
    // All operations use original stable IDs; apply field/move changes before renames.
    next.operations = next.operations.filter((op: EditOperation) => op.kind !== 'rename')
      .concat(next.operations.filter((op: EditOperation) => op.kind === 'rename'));
    return next;
  }

  export function remove(intent: EditIntent, section: string, target: EditTarget, action: string): EditIntent {
    const next = copy(intent);
    next.operations = next.operations.filter((op: EditOperation) => op.target !== target.item.id || op.section !== section);
    const deletion: EditOperation = { id: action, kind: 'delete', section: section,
      target: target.item.id, expected: target.item.revision };
    next.operations.unshift(deletion);
    return next;
  }

  export function restore(intent: EditIntent, section: string, id: string): EditIntent {
    const next = copy(intent);
    next.operations = next.operations.filter((op: EditOperation) =>
      op.kind !== 'delete' || op.section !== section || op.target !== id);
    return next;
  }

  export function move(intent: EditIntent, section: string, id: string, before: string, action: string): EditIntent {
    const next = copy(intent);
    next.operations = next.operations.filter((op: EditOperation) =>
      op.kind !== 'move' || op.section !== section || op.target !== id);
    next.operations.unshift({ id: action, kind: 'move', section: section, target: id, before: before });
    return next;
  }
}
