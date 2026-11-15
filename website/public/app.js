const copy = document.getElementById('copy');
const cmd = document.getElementById('install-cmd');

if (copy && cmd) {
  copy.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(cmd.textContent.trim());
      copy.textContent = '已复制';
      copy.classList.add('done');
      setTimeout(() => {
        copy.textContent = '复制';
        copy.classList.remove('done');
      }, 1600);
    } catch {
      const range = document.createRange();
      range.selectNodeContents(cmd);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    }
  });
}
