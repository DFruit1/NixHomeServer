import { component$ } from '@builder.io/qwik';

const tokenClass = (token: string) => {
  if (/^\s+$/.test(token)) {
    return '';
  }
  if (token === '\\') {
    return 'syntax-continuation';
  }
  if (/^(sshfs|ssh-keygen|mkdir|chmod|cat|net|umount|fusermount|systemctl|launchctl|New-Item|Get-Content|Out-Null)$/.test(token)) {
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

export const CommandSnippet = component$(({ command, class: className }: { command: string; class?: string }) => (
  <pre class={`command-snippet${className ? ` ${className}` : ''}`}>
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
));
