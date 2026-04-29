// Re-export the portable client package so consumers that `import
// MultiharnessCore` keep seeing Project, Workspace, ProviderRecord,
// ControlClient, etc. without having to add a second import.
@_exported import MultiharnessClient
