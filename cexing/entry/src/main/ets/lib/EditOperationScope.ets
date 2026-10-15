import { EditIntent, EditOperation } from './ConfigEditor';

/** Template-owned edits remain stored while another template is selected. */
export function isEditOperationActive(intent: EditIntent, operation: EditOperation): boolean {
  return operation.templateId === undefined || operation.templateId === '' ||
    operation.templateId === intent.template?.templateId;
}
