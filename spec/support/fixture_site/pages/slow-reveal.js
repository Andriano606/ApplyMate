// trigger.html: the form is injected 1.5 s after the button is clicked (a slow SPA).
document.getElementById('open-form').addEventListener('click', () => {
  setTimeout(() => {
    document.getElementById('slot').innerHTML =
      '<form id="late-form" action="/submit" method="post">' +
      '<label for="late_name">Name</label><input id="late_name" name="late_name" type="text">' +
      '<label for="late_email">Email</label><input id="late_email" name="late_email" type="email">' +
      '<button type="submit">Send</button></form>';
  }, 1500);
});
