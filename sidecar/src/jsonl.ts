import { mkdir, appendFile } from "node:fs/promises";
import { dirname } from "node:path";

export class JsonlWriter {
  private prepared = false;
  private queue: Promise<void> = Promise.resolve();

  constructor(private readonly filePath: string) {}

  async append(record: unknown): Promise<void> {
    const line = JSON.stringify(record) + "\n";
    this.queue = this.queue.then(async () => {
      if (!this.prepared) {
        await mkdir(dirname(this.filePath), { recursive: true });
        this.prepared = true;
      }
      await appendFile(this.filePath, line, "utf8");
    });
    return this.queue;
  }

  async close(): Promise<void> {
    await this.queue;
  }
}
