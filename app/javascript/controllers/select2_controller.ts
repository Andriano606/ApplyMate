import { Controller } from '@hotwired/stimulus';
import type { AjaxOptions, Options, QueryOptions } from 'select2';
import $ from 'jquery';

// select2 v4 UMD exports a factory in CJS environments.
// Using require() (not import) so bun executes it here — after window.jQuery
// is already set by jquery.ts — instead of hoisting it before module bodies run.
// eslint-disable-next-line @typescript-eslint/no-require-imports
const s2 = require('select2') as
  | ((root: Window, jq: JQueryStatic) => void)
  | undefined;
if (typeof s2 === 'function') s2(window, $);

export default class Select2Controller extends Controller {
  connect(): void {
    this.#init();
  }

  refreshUrl(): void {
    const $el = $(this.#el);
    const currentValues = $el.val();
    this.#destroy();
    if (currentValues !== undefined) {
      $el.val(currentValues as string | string[]);
    }
    this.#init();
  }

  disconnect(): void {
    this.#destroy();
  }

  get #el(): HTMLSelectElement {
    return this.element as HTMLSelectElement;
  }

  #init(): void {
    const el = this.#el;
    if (el.classList.contains('select2-hidden-accessible')) return;

    const modal = el.closest('.modal') as HTMLElement | null;
    const placeholder =
      el.dataset.placeholder ||
      el.querySelector('option[value=""]')?.textContent ||
      '';

    const options: Options = {
      theme: 'default',
      placeholder,
      allowClear: true,
      dropdownParent: modal ? $(modal) : $(document.body),
      width: '100%',
    };

    const ajaxUrl = el.dataset.ajaxUrl;
    if (ajaxUrl) {
      const ajax: AjaxOptions = {
        transport: (params, success, failure) =>
          $.ajax({
            ...params,
            type: 'GET',
            url: el.dataset.ajaxUrl!,
            dataType: 'json',
          })
            .done(success)
            .fail(failure),
        delay: 250,
        data: (params: QueryOptions) => ({
          search: params.term,
          page: params.page || 1,
        }),
        processResults: (data) => ({
          results: data.result ?? [],
          pagination: { more: !!data?.pagination?.more },
        }),
        cache: false,
      };
      options.ajax = ajax;
      options.minimumInputLength = 0;
    }

    const $el = $(el);
    $el.select2(options);
    $el.on('select2:select', () =>
      el.dispatchEvent(new Event('change', { bubbles: true })),
    );
    $el.on('select2:clear', () =>
      el.dispatchEvent(new Event('change', { bubbles: true })),
    );
  }

  #destroy(): void {
    const el = this.#el;
    if (!el.classList.contains('select2-hidden-accessible')) return;
    const $el = $(el);
    $el.off('select2:select select2:clear');
    $el.select2('destroy');
  }
}
