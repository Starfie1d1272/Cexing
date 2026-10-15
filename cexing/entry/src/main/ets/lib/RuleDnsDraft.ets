import { isEditOperationActive } from './EditOperationScope';
import { EditIntent, EditOperation } from './ConfigEditor';

// In-memory composition only. Persistence/CAS and publication remain entirely
// owned by ProfileTransactions.save/preview/applyEditDraft.
export class RuleDnsDraft {
  static moveAdded(intent: EditIntent, section: string, from: number, to: number): EditIntent {
    const next = JSON.parse(JSON.stringify(intent)) as EditIntent;
    const added = next.operations.filter((op: EditOperation) => isEditOperationActive(next, op) && op.kind === 'add' && op.section === section);
    if (from < 0 || to < 0 || from >= added.length || to >= added.length) { throw new Error('无效的规则位置'); }
    const moved = added[from];
    const destination = added[to];
    if (section === 'rules' && (typeof moved.value === 'string' && (moved.value as string).startsWith('MATCH,') ||
      typeof destination.value === 'string' && (destination.value as string).startsWith('MATCH,'))) { throw new Error('最终规则保持在末尾'); }
    moved.before = destination.before;
    added.splice(from, 1); added.splice(to, 0, moved);
    let index = 0;
    next.operations = next.operations.map((op: EditOperation) => isEditOperationActive(next, op) && op.kind === 'add' && op.section === section ? added[index++] : op);
    return next;
  }

  static put(intent: EditIntent, operation: EditOperation): EditIntent {
    const next = JSON.parse(JSON.stringify(intent)) as EditIntent;
    if (next.operations.some((old: EditOperation) => old.id === operation.id && !isEditOperationActive(next, old))) {
      throw new Error('编辑操作已变化，请重新打开');
    }
    if (operation.section === 'rules' || operation.kind === 'delete' || operation.kind === 'rename' || operation.kind === 'move') {
      next.operations.push(operation); return next;
    }
    const index = next.operations.findIndex((old: EditOperation) => isEditOperationActive(next, old) && (old.id === operation.id ||
      (old.kind === 'update' && operation.kind === 'update' && old.section === operation.section && old.target === operation.target)));
    if (index >= 0 && operation.patch !== undefined && next.operations[index].patch !== undefined) {
      const old = next.operations[index];
      const patch: Record<string, Object> = {}; const conditions: Record<string, string> = {};
      for (const key of Object.keys(old.patch!)) { patch[key] = old.patch![key]; conditions[key] = old.preconditions![key]; }
      for (const key of Object.keys(operation.patch)) { patch[key] = operation.patch[key]; conditions[key] = conditions[key] ?? operation.preconditions![key]; }
      const remove = (old.remove ?? []).filter((key: string) => !Object.keys(operation.patch!).includes(key));
      for (const key of operation.remove ?? []) { conditions[key] = conditions[key] ?? operation.preconditions![key]; if (!remove.includes(key)) { remove.push(key); } }
      const retained: Record<string, Object> = {};
      for (const key of Object.keys(patch)) { if (!remove.includes(key)) { retained[key] = patch[key]; } }
      next.operations[index] = { id: operation.id, kind: 'update', section: operation.section, target: operation.target, templateId: old.templateId, patch: retained, preconditions: conditions, remove };
    } else if (index >= 0) {
      // A projected scalar revision belongs to the intermediate draft. When
      // replacing its operation, retain the original source guard.
      const old = next.operations[index];
      operation = JSON.parse(JSON.stringify(operation)) as EditOperation;
      if (old.kind === 'update' && operation.kind === 'update' && old.expected !== undefined) {
        operation.expected = old.expected;
      }
      operation.templateId = old.templateId;
      next.operations[index] = operation;
    }
    else { next.operations.push(operation); }
    return next;
  }
}
