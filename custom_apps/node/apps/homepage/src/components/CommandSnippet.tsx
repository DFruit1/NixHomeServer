import { $, component$, useSignal } from '@builder.io/qwik';

const tokenClass = (token: string) => {
  if (/^\s+$/.test(token)) {
    return '';
  }
  if (token === '\\') {
    return 'syntax-continuation';
  }
  if (/^(sshfs|ssh-keygen|mkdir|chmod|cat|net|umount|fusermount|systemctl|launchctl|New-Item|Get-Content|Out-Null|sudo|ln|sv|xbps-install)$/.test(token)) {
    return 'syntax-command';
  }
  if (/^(-[A-Za-z0-9]+|\/[A-Za-z]+:|-[A-Za-z0-9]+)$/.test(token) || token.startsWith('-o')) {
    return 'syntax-option';
  }
  if (token.includes('=') || token.startsWith('$') || token.startsWith('%')) {
    return 'syntax-variable';
  }
  if (token.startsWith('~/') || token.startsWith('%h/') || token.startsWith('$HOME/') || token.startsWith('$env:')) {
    return 'syntax-path';
  }
  if (token.includes('@') && token.includes(':/')) {
    return 'syntax-target';
  }
  if (/^["'].*["']$/.test(token)) {
    return 'syntax-string';
  }
  return '';
};

const tokenize = (command: string) => command.match(/\s+|[^\s]+/g) ?? [];

/**
 * A command to run on the reader's own device. The optional class (for example
 * an OS panel) is applied to both the wrapper and the <pre>, so a hidden panel
 * hides its Copy button with it.
 */
export const CommandSnippet = component$(({ command, class: className }: { command: string; class?: string }) => {
  const copied = useSignal(false);
  const extraClass = className ? ` ${className}` : '';

  const copyCommand = $(async () => {
    try {
      await navigator.clipboard.writeText(command);
    } catch {
      return;
    }
    copied.value = true;
    window.setTimeout(() => {
      copied.value = false;
    }, 1600);
  });

  return (
    <div class={`command-snippet-wrap${extraClass}`}>
      <pre class={`command-snippet${extraClass}`}>
        <code>
          {tokenize(command).map((token, index) => {
            const classForToken = tokenClass(token);
            return classForToken ? (
              <span class={classForToken} key={`${index}-${token}`}>
                {token}
              </span>
            ) : (
              token
            );
          })}
        </code>
      </pre>
      <button type="button" class="command-snippet__copy" aria-label={copied.value ? 'Copied command' : 'Copy command'} onClick$={copyCommand}>
        {copied.value ? 'Copied' : 'Copy'}
      </button>
    </div>
  );
});
