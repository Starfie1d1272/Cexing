import { isEditOperationActive } from './EditOperationScope';
import { EditIntent, EditOperation, EditTarget } from './ConfigEditor';
import { ProxyMappingDraft } from './ProxyMappingForm';

/** Local field-operation construction against the compiler's original target.
 * No YAML compilation, persistence, or guessed fingerprints occur here. */
export namespace ProxyIntentEdits {
  function copy(intent: EditIntent): EditIntent { return JSON.parse(JSON.stringify(intent)) as EditIntent; }

  // Reorder only active slots; dormant edits keep their order and contents.
  function orderActiveRenames(intent: EditIntent): void {
    const active = intent.operations.filter((op: EditOperation) => isEditOperationActive(intent, op));
    const ordered = active.filter((op: EditOperation) => op.kind !== 'rename')
      .concat(active.filter((op: EditOperation) => op.kind === 'rename'));
    let index = 0;
    intent.operations = intent.operations.map((op: EditOperation) =>
      isEditOperationActive(intent, op) ? ordered[index++] : op);
  }

  export function mapping(intent: EditIntent, original: EditTarget | null,
    draft: ProxyMappingDraft, action: string, missingFieldRevision: string): EditIntent {
    const next = copy(intent);
    if (original === null) {
      const existing = next.operations.findIndex((operation: EditOperation) => isEditOperationActive(next, operation) && operation.id === action);
      const addition: EditOperation = { id: action, kind: 'add', section: draft.section,
        name: draft.name, value: draft.value };
      if (existing < 0) {
        if (next.operations.some((op: EditOperation) => op.id === action)) { throw new Error('新增操作已变化，请重新打开'); }
        next.operations.push(addition);
      }
      else {
        const previous = next.operations[existing];
        if (previous.kind !== 'add' || previous.section !== draft.section) { throw new Error('新增操作已变化，请重新打开'); }
        addition.templateId = previous.templateId; addition.before = previous.before; next.operations[existing] = addition;
      }
      return next;
    }
    const id = original.item.id;
    next.operations = next.operations.filter((op: EditOperation) =>
      !isEditOperationActive(next, op) || op.section !== draft.section || op.target !== id || (op.kind !== 'update' && op.kind !== 'rename'));
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
    orderActiveRenames(next);
    return next;
  }

  export function remove(intent: EditIntent, section: string, target: EditTarget, action: string): EditIntent {
    const next = copy(intent);
    next.operations = next.operations.filter((op: EditOperation) => !isEditOperationActive(next, op) || op.target !== target.item.id || op.section !== section);
    const deletion: EditOperation = { id: action, kind: 'delete', section: section,
      target: target.item.id, expected: target.item.revision };
    next.operations.unshift(deletion);
    return next;
  }

  export function restore(intent: EditIntent, section: string, id: string): EditIntent {
    const next = copy(intent);
    next.operations = next.operations.filter((op: EditOperation) =>
      !isEditOperationActive(next, op) || op.kind !== 'delete' || op.section !== section || op.target !== id);
    return next;
  }

  /** Keep node references intact; the common compiler supplies the reject adapter. */
  export function nodeDisabled(intent: EditIntent, id: string, addition: boolean = false): boolean {
    return intent.operations.some((op: EditOperation) => isEditOperationActive(intent, op) && op.section === 'proxies' && op.kind === 'disable' &&
      (addition ? op.id === `${id}:disable` : op.target === id));
  }

  export function enableNode(intent: EditIntent, id: string, addition: boolean = false): EditIntent {
    const next = copy(intent);
    next.operations = next.operations.filter((op: EditOperation) => !isEditOperationActive(next, op) || op.section !== 'proxies' || op.kind !== 'disable' ||
      (addition ? op.id !== `${id}:disable` : op.target !== id));
    return next;
  }

  export function disableNode(intent: EditIntent, target: EditTarget, action: string): EditIntent {
    const next = enableNode(intent, target.item.id);
    if (next.operations.some((op: EditOperation) => op.id === action)) { throw new Error('NODE_OPERATION_CHANGED'); }
    const operation: EditOperation = { id: action, kind: 'disable', section: 'proxies',
      target: target.item.id, expected: target.item.revision };
    next.operations.push(operation);
    orderActiveRenames(next);
    return next;
  }

  export function removeAddition(intent: EditIntent, id: string): EditIntent {
    const next = enableNode(intent, id, true);
    next.operations = next.operations.filter((op: EditOperation) => !isEditOperationActive(next, op) || op.id !== id);
    return next;
  }

  export function move(intent: EditIntent, section: string, id: string, before: string, action: string): EditIntent {
    const next = copy(intent);
    next.operations = next.operations.filter((op: EditOperation) =>
      !isEditOperationActive(next, op) || op.kind !== 'move' || op.section !== section || op.target !== id);
    next.operations.unshift({ id: action, kind: 'move', section: section, target: id, before: before });
    return next;
  }
}
