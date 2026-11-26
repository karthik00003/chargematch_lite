// Inline validation for every form of the app (the same rules are checked again by Flask and by MySQL).
//  * the rules come from the HTML: required, pattern, min / max / step, minlength / maxlength, type=email
//  * text is trimmed: a field with only spaces counts as empty
//  * data-match="other"  -> must equal that field (confirm password)
//  * data-after="other"  -> a number / time that must be greater than the other field (end % > start %)
//  * messages are short and fixed ("Minimum 3 characters", "Enter a value between 5 and 30"), never live counters;
//    a field can set its own with data-msg-required / data-msg-pattern (or title) / data-msg-range
//  * a message appears only when the user tries to submit (Enter, Submit, Continue) with a wrong value, and goes
//    away as soon as that value is valid; buttons are never disabled by this file
//  * forms with data-validate-self are submitted by their own script (the listing steps, the charger forms):
//    this file only provides FormCheck.check(root, attempt) for them
(function () {
  const TEXT = ["text", "email", "tel", "search", "password", "url"];
  const isText = (el) => el.tagName === "TEXTAREA" || (el.tagName === "INPUT" && TEXT.includes(el.type));

  function fieldsOf(root) {
    return [...root.querySelectorAll("input, select, textarea")]
      .filter((el) => el.name && !el.disabled && !["hidden", "submit", "button", "reset", "file"].includes(el.type));
  }

  // custom rules -> setCustomValidity, so el.validity.valid covers everything
  function customRule(el) {
    const form = el.form;
    let msg = "";
    if (isText(el)) {
      const t = el.value.trim();
      if (el.value !== "" && t === "") msg = el.dataset.msgRequired || "This field is required";
      else if (t && el.minLength > 0 && t.length < el.minLength) msg = `Minimum ${el.minLength} characters`;
    }
    if (!msg && el.dataset.match && el.value && form && el.value !== (form.elements[el.dataset.match] || {}).value)
      msg = el.dataset.msgMatch || "The two values don't match";
    if (!msg && el.dataset.after && el.value !== "" && form) {
      const other = form.elements[el.dataset.after];
      if (other && other.value !== "") {
        const isTime = /^\d{2}:\d{2}/.test(el.value) && /^\d{2}:\d{2}/.test(other.value);
        const later = isTime ? el.value > other.value : Number(el.value) > Number(other.value);
        if (!later) msg = el.dataset.msgAfter || `Must be greater than ${other.value}`;
      }
    }
    el.setCustomValidity(msg);
    return msg;
  }

  function message(el) {
    const v = el.validity, d = el.dataset;
    if (v.customError) return el.validationMessage;
    if (v.valueMissing) return d.msgRequired || (el.tagName === "SELECT" ? "Choose an option"
                             : el.type === "checkbox" ? "Tick this box" : "This field is required");
    if (v.patternMismatch) return d.msgPattern || el.title || "Wrong format";
    if (v.typeMismatch) return el.type === "email" ? "Enter a valid email address" : d.msgPattern || "Wrong format";
    if (v.badInput) return d.msgRange || "Enter a number";
    if (v.rangeUnderflow || v.rangeOverflow) {
      if (d.msgRange) return d.msgRange;
      if (el.min !== "" && el.max !== "") return `Enter a value between ${el.min} and ${el.max}`;
      return v.rangeUnderflow ? `Minimum ${el.min}` : `Maximum ${el.max}`;
    }
    if (v.stepMismatch) return d.msgStep || d.msgRange || "Enter a valid value";
    if (v.tooShort) return `Minimum ${el.minLength} characters`;
    if (v.tooLong) return `Maximum ${el.maxLength} characters`;
    return "Invalid value";
  }

  function errorBox(el) {
    const scope = el.closest("label") || el.parentElement;
    let box = scope.querySelector(`.field-error[data-for="${CSS.escape(el.name)}"]`);
    if (!box) {
      box = document.createElement("small");
      box.className = "field-error";
      box.dataset.for = el.name;
      box.setAttribute("aria-live", "polite");
      (el.type === "checkbox" || el.type === "radio" ? scope : el).insertAdjacentElement(
        el.type === "checkbox" || el.type === "radio" ? "beforeend" : "afterend", box);
    }
    return box;
  }

  function render(el) {
    const show = el.dataset.flagged === "1";
    el.classList.toggle("invalid", show);
    el.setAttribute("aria-invalid", show ? "true" : "false");
    const label = el.closest("label");
    if (label) label.classList.toggle("has-error", show);
    const box = show ? errorBox(el) : (el.closest("label") || el.parentElement)
      .querySelector(`.field-error[data-for="${CSS.escape(el.name)}"]`);
    if (box) { box.textContent = show ? message(el) : ""; box.hidden = !show; }
  }

  // check(root, attempt): recompute every field; attempt = an Enter / Submit / Continue press, which flags the
  // wrong fields so their messages show. A flagged field is unflagged as soon as it is valid. Returns true if all OK.
  function check(root, attempt = false) {
    let ok = true;
    fieldsOf(root).forEach((el) => {
      customRule(el);
      const valid = el.validity.valid;
      if (!valid) ok = false;
      if (valid) delete el.dataset.flagged;
      else if (attempt) el.dataset.flagged = "1";
      render(el);
    });
    // fields switched off (e.g. "Open 24 hours") lose their message too
    root.querySelectorAll("[data-flagged]:disabled").forEach((el) => { delete el.dataset.flagged; render(el); });
    return ok;
  }

  function onEdit(e) {
    const el = e.target, form = el.form;
    if (!form || !el.name || form.dataset.chargerForm !== undefined) return;   // charger forms: host.js
    check(form);                                   // only clears / refreshes the messages already showing
  }

  // Our messages replace the browser's bubbles on every form (also ones added to the page later).
  const quiet = (form) => { if (form && !form.noValidate) form.noValidate = true; };
  document.querySelectorAll("form").forEach(quiet);
  document.addEventListener("click", (e) => {
    const b = e.target.closest && e.target.closest("button, input[type=submit]");
    if (b && b.form) quiet(b.form);
  }, true);
  document.addEventListener("keydown", (e) => { if (e.key === "Enter" && e.target.form) quiet(e.target.form); }, true);
  document.addEventListener("input", onEdit);
  document.addEventListener("change", onEdit);

  // window + capture: runs before any other submit handler (confirm dialogs, double-submit guard)
  window.addEventListener("submit", (e) => {
    const form = e.target;
    if (form.dataset.validateSelf !== undefined) return;
    fieldsOf(form).forEach((el) => { if (isText(el) && el.type !== "password") el.value = el.value.trim(); });
    if (!check(form, true)) {
      e.preventDefault();
      e.stopImmediatePropagation();
      const first = fieldsOf(form).find((el) => el.dataset.flagged === "1");
      if (first) first.focus();
    }
  }, true);

  window.FormCheck = { check, fieldsOf };
})();
