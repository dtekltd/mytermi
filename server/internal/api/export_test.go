package api

import "time"

// SetSettingsForTest replaces the cached settings (tests only).
func SetSettingsForTest(s *Server, st Settings) {
	s.mu.Lock()
	s.settings, s.settingsAt = &st, time.Now()
	s.mu.Unlock()
}
