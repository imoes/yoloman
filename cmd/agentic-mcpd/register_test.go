package main

import "testing"

func TestAdvertisedAddress(t *testing.T) {
	cases := []struct {
		name          string
		agentName     string
		addressFlag   string
		cfgListen     string
		wantAdvertise string
		wantListen    string
	}{
		{
			// Zero-touch, the vpp0221 case: no --address, default listen.
			// Must produce a reachable address from the name, not empty.
			name:          "no address flag, default listen",
			agentName:     "vpp0221.example.com",
			addressFlag:   "",
			cfgListen:     "127.0.0.1:8010",
			wantAdvertise: "vpp0221.example.com:8010",
			wantListen:    "0.0.0.0:8010",
		},
		{
			name:          "no address flag, custom listen port",
			agentName:     "host.example.com",
			addressFlag:   "",
			cfgListen:     "127.0.0.1:18051",
			wantAdvertise: "host.example.com:18051",
			wantListen:    "0.0.0.0:18051",
		},
		{
			name:          "no address flag, empty listen falls back to 8010",
			agentName:     "host.example.com",
			addressFlag:   "",
			cfgListen:     "",
			wantAdvertise: "host.example.com:8010",
			wantListen:    "0.0.0.0:8010",
		},
		{
			name:          "address flag host:port overrides both",
			agentName:     "shortname",
			addressFlag:   "public.example.com:9999",
			cfgListen:     "127.0.0.1:8010",
			wantAdvertise: "public.example.com:9999",
			wantListen:    "0.0.0.0:9999",
		},
		{
			name:          "address flag host only keeps listen port",
			agentName:     "shortname",
			addressFlag:   "public.example.com",
			cfgListen:     "127.0.0.1:8010",
			wantAdvertise: "public.example.com:8010",
			wantListen:    "0.0.0.0:8010",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			adv, listen := advertisedAddress(tc.agentName, tc.addressFlag, tc.cfgListen)
			if adv != tc.wantAdvertise {
				t.Errorf("advertise: got %q, want %q", adv, tc.wantAdvertise)
			}
			if listen != tc.wantListen {
				t.Errorf("listen: got %q, want %q", listen, tc.wantListen)
			}
		})
	}
}
