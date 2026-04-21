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
