import { EditIntent, EditOperation } from './ConfigEditor';

// In-memory composition only. Persistence/CAS and publication remain entirely
// owned by ProfileTransactions.save/preview/applyEditDraft.
export class RuleDnsDraft {
  static put(intent: EditIntent, operation: EditOperation): EditIntent {
    const next = JSON.parse(JSON.stringify(intent)) as EditIntent;
    if (operation.kind === 'delete') { next.operations = next.operations.filter((op: EditOperation) => op.target !== operation.target); }
    const index = next.operations.findIndex((old: EditOperation) => old.id === operation.id ||
      (old.kind === 'update' && operation.kind === 'update' && old.section === operation.section && old.target === operation.target));
    if (index >= 0 && operation.patch !== undefined && next.operations[index].patch !== undefined) {
      const old = next.operations[index];
      const patch: Record<string, Object> = {}; const conditions: Record<string, string> = {};
      for (const key of Object.keys(old.patch!)) { patch[key] = old.patch![key]; conditions[key] = old.preconditions![key]; }
      for (const key of Object.keys(operation.patch)) { patch[key] = operation.patch[key]; conditions[key] = operation.preconditions![key]; }
      const remove = (old.remove ?? []).filter((key: string) => !Object.keys(operation.patch!).includes(key));
      for (const key of operation.remove ?? []) { conditions[key] = operation.preconditions![key]; if (!remove.includes(key)) { remove.push(key); } }
      const retained: Record<string, Object> = {};
      for (const key of Object.keys(patch)) { if (!remove.includes(key)) { retained[key] = patch[key]; } }
      next.operations[index] = { id: operation.id, kind: 'update', section: operation.section, target: operation.target, patch: retained, preconditions: conditions, remove };
    } else if (index >= 0) { next.operations[index] = operation; }
    else { next.operations.push(operation); }
    // Source IDs/anchors must be used before updates/renames change their identity.
    next.operations = next.operations.filter((op: EditOperation) => op.kind === 'move' || op.kind === 'add').concat(
      next.operations.filter((op: EditOperation) => op.kind !== 'move' && op.kind !== 'add' && op.kind !== 'rename')).concat(
      next.operations.filter((op: EditOperation) => op.kind === 'rename'));
    next.disabled = false;
    return next;
  }
}
