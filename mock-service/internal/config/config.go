package config

import (
	"fmt"
	"os"
)

// Config holds all required environment variable values for the service.
type Config struct {
	DBConnectionString string
	ProviderAPIKey     string
	EncryptionKey      string
	ServiceEnv         string
	Port               string
}

// Load reads required environment variables and returns a Config.
// It returns an error if any required variable is missing or empty.
func Load() (*Config, error) {
	required := map[string]string{
		"DB_CONNECTION_STRING": "",
		"PROVIDER_API_KEY":     "",
		"ENCRYPTION_KEY":       "",
		"SERVICE_ENV":          "",
	}

	var missing []string
	for key := range required {
		val := os.Getenv(key)
		if val == "" {
			missing = append(missing, key)
		}
		required[key] = val
	}

	if len(missing) > 0 {
		return nil, fmt.Errorf("missing required environment variables: %v", missing)
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	return &Config{
		DBConnectionString: required["DB_CONNECTION_STRING"],
		ProviderAPIKey:     required["PROVIDER_API_KEY"],
		EncryptionKey:      required["ENCRYPTION_KEY"],
		ServiceEnv:         required["SERVICE_ENV"],
		Port:               port,
	}, nil
}
