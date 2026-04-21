import { Controller } from '@hotwired/stimulus';

// Global controller mounted on <body>.
// Listens for Turbo form events that bubble up from any form on the page,
// disables submit buttons on submit-start and re-enables them on failure.
export default class extends Controller {
  connect() {
    this.element.addEventListener(
      'turbo:submit-start',
      this.#handleSubmitStart,
    );
    this.element.addEventListener('turbo:submit-end', this.#handleSubmitEnd);
  }

  disconnect() {
    this.element.removeEventListener(
      'turbo:submit-start',
      this.#handleSubmitStart,
    );
    this.element.removeEventListener('turbo:submit-end', this.#handleSubmitEnd);
  }

  #handleSubmitStart = (event: Event) => {
    const form = event.target as HTMLFormElement;
    this.#submitButtons(form).forEach((btn) => this.#setLoading(btn, true));
  };

  #handleSubmitEnd = (event: Event) => {
    const detail = (event as CustomEvent).detail as { success: boolean };
    if (detail.success) return;

    const form = event.target as HTMLFormElement;
    this.#submitButtons(form).forEach((btn) => this.#setLoading(btn, false));
  };

  #submitButtons(form: HTMLFormElement): HTMLButtonElement[] {
    const inside = Array.from(
      form.querySelectorAll<HTMLButtonElement>('[type="submit"]'),
    );
    const outside = form.id
      ? Array.from(
          document.querySelectorAll<HTMLButtonElement>(
            `[type="submit"][form="${form.id}"]`,
          ),
        )
      : [];
    return [...inside, ...outside];
  }

  #setLoading(btn: HTMLButtonElement, loading: boolean) {
    if (loading) {
      btn.disabled = true;
      btn.dataset.originalHtml = btn.innerHTML;
      btn.innerHTML = `
        <span class="inline-flex items-center gap-2 justify-center">
          <svg class="animate-spin h-4 w-4 shrink-0" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" aria-hidden="true">
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
            <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
          </svg>
          <span>${btn.textContent?.trim() ?? ''}</span>
        </span>`;
    } else {
      btn.disabled = false;
      btn.innerHTML = btn.dataset.originalHtml ?? btn.innerHTML;
      delete btn.dataset.originalHtml;
    }
  }
}
