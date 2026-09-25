// Connection status + manual reconnect for the FastTab Companion options page.
const statusEl = document.getElementById('status');
const button = document.getElementById('reconnect');

function refresh() {
  chrome.runtime.sendMessage({ type: 'getStatus' }, (res) => {
    const connected = !!(res && res.connected);
    if (connected) {
      statusEl.textContent = 'Connected to FastTab ✓';
      statusEl.className = 'ok';
      document.getElementById('detail').textContent = '';
    } else {
      statusEl.textContent = 'Not connected — is the FastTab app running?';
      statusEl.className = 'bad';
      document.getElementById('detail').textContent = (res && res.error) ? 'Error: ' + res.error : '';
    }
  });
}

button.addEventListener('click', () => {
  button.disabled = true;
  chrome.runtime.sendMessage({ type: 'reconnect' }, () => {
    button.disabled = false;
    refresh();
  });
});

refresh();
setInterval(refresh, 2000);
