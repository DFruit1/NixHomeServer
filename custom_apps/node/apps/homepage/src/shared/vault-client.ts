export type VaultApiResult<T> = {
  status: number;
  data?: T & { error?: string };
  error?: string;
};

export const vaultRequest = async <T>(
  method: 'GET' | 'POST' | 'DELETE',
  path: string,
  body?: unknown,
): Promise<VaultApiResult<T>> => {
  try {
    const response = await fetch(path, {
      method,
      headers: { 'content-type': 'application/json', accept: 'application/json' },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    const data = (await response.json().catch(() => ({}))) as T & { error?: string };
    return { status: response.status, data, error: data?.error };
  } catch {
    return { status: 0, error: 'The request could not be sent.' };
  }
};

export const copyVaultSecret = async (value: string): Promise<boolean> => {
  try {
    await navigator.clipboard.writeText(value);
    return true;
  } catch {
    return false;
  }
};
