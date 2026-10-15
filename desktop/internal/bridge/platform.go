package bridge

// Keep platform policy at the service boundary. The JSON controller operations
// are shared; a future Windows HID service can implement the same contract.
func platformSupport(goos string) (bool, string) {
	switch goos {
	case "linux", "darwin":
		return true, ""
	case "windows":
		return false, "Windows controller support is not implemented yet. This build cannot read or configure hardware on Windows."
	default:
		return false, "Controller support is available on Linux and macOS."
	}
}

func serviceExecutableName(goos string) string {
	if goos == "windows" {
		return "freedigi-service.exe"
	}
	return "freedigi-service"
}
