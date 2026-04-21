export async function handleErrors(response: Response): Promise<void> {
  if (!response.ok && response.status === 500) {
    console.error('Server error:', response.status, response.url);
  }
}
