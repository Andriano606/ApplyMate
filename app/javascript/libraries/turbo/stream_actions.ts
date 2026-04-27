import { StreamActions } from '@hotwired/turbo';
import { Turbo } from '@hotwired/turbo-rails';

StreamActions.create_element_if_not_exist = function (this: Element): void {
  const targetId = this.getAttribute('target');
  if (!targetId) return;

  const target = document.getElementById(targetId);

  // Only insert if it doesn't already exist:
  if (!target) {
    const parentId = this.getAttribute('parent_id');
    if (!parentId) return;

    const parentElement = document.getElementById(parentId);
    if (!parentElement) {
      console.error(`Couldn't find parent ${parentId} to insert ${targetId}`);
      return;
    }
    const newElement = document.createElement('div');
    newElement.setAttribute('id', targetId);
    parentElement.appendChild(newElement);
  }
};

StreamActions.remove_by_id = function () {
  let target = document.querySelector(
    `[data-model-id='${this.getAttribute('target')}']`,
  );
  target?.remove();
};

StreamActions.redirect = function () {
  const target = this.getAttribute('target');
  if (!target) return;
  Turbo.visit(target);
};

StreamActions.close_active_modal = function () {
  const modals = document.querySelectorAll('[data-controller="turbo-modal"]');
  if (!modals.length) return;
  const lastModal = modals[modals.length - 1];
  // Dispatch click directly on the overlay element so closeBackground sees event.target === overlayTarget
  lastModal.dispatchEvent(new MouseEvent('click', { bubbles: false }));
};

StreamActions.select_option = function (this: any) {
  const targetId = this.getAttribute('target');
  if (!targetId) return;

  const target = document.getElementById(targetId) as HTMLSelectElement | null;
  if (!target) return;

  target.appendChild(this.templateContent);
  target.selectedIndex = target.options.length - 1;

  // This part is mostly for legacy, where some stimulus controllers expect an event. When the relevant forms use turbo
  // to update the form we can probably remove this.
  // The known places we expect a callback is:
  // - app/concepts/sale/invoice/component/new.slim
  // - app/concepts/offer/component/new.slim
  // - app/concepts/purchase/asset/component/sell_asset_modal.slim
  const option = target.selectedOptions[0];
  if (!option) return;

  const attributes: Record<string, string | null> = {};
  option
    .getAttributeNames()
    .forEach((attr) => (attributes[attr] = option.getAttribute(attr)));
  target.dispatchEvent(new CustomEvent('change', { detail: attributes }));
};
