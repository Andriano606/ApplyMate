import { Controller } from '@hotwired/stimulus';

const SELECTED = ['!border-green-500', '!bg-green-50'];
const UNSELECTED = [
  'border-gray-200',
  'bg-white',
  'hover:border-gray-300',
  'hover:bg-gray-50',
];

export default class SelectOptionController extends Controller {
  connect() {
    this.updateCard();
  }

  onChange(event: Event) {
    const radio = event.target as HTMLInputElement;
    document
      .querySelectorAll<HTMLInputElement>(
        `input[type="radio"][name="${CSS.escape(radio.name)}"]`,
      )
      .forEach((r) => {
        const label = r.closest('label');
        if (!label) return;
        const card = label.querySelector<HTMLElement>('.select-option-card');
        if (!card) return;
        this.setCardState(card, r.checked);
      });
  }

  private updateCard() {
    const radio = this.element.querySelector<HTMLInputElement>(
      'input[type="radio"]',
    );
    if (!radio) return;
    const card = this.element.querySelector<HTMLElement>('.select-option-card');
    if (!card) return;
    this.setCardState(card, radio.checked);
  }

  private setCardState(card: HTMLElement, checked: boolean) {
    if (checked) {
      card.classList.remove(...UNSELECTED);
      card.classList.add(...SELECTED);
    } else {
      card.classList.remove(...SELECTED);
      card.classList.add(...UNSELECTED);
    }
  }
}
