// The sync server's answer (server/src/stats/api.ts, SyncStats). Keep the two in step.

export interface DayValue {
  day: string;
  value: number;
}

export interface SyncStats {
  generatedAt: string;
  environment: string;
  current: {
    accounts: number;
    active7d: number;
    active30d: number;
    devices: Record<string, number>;
    recordsLive: number;
    draftsLive: number;
  };
  newAccounts: DayValue[];
  feedback: { day: string; kind: string; value: number }[];
  daily: Record<string, DayValue[]>;
}
