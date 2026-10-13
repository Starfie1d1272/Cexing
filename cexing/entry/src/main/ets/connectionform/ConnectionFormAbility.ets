import { Want } from '@kit.AbilityKit';
import { FormExtensionAbility, formBindingData, formInfo } from '@kit.FormKit';
import { ConnectionCards } from '../lib/ConnectionCards';

export default class ConnectionFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const id = want.parameters?.[formInfo.FormParam.IDENTITY_KEY];
    if (typeof id === 'string') { ConnectionCards.add(this.context, id); }
    return formBindingData.createFormBindingData(ConnectionCards.read(this.context));
  }

  onUpdateForm(formId: string): void {
    ConnectionCards.update(this.context, formId);
  }

  onRemoveForm(formId: string): void {
    ConnectionCards.remove(this.context, formId);
  }
}
