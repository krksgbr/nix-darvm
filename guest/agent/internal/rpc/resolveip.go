package rpc

import (
	"context"
	"fmt"
	"net"
	"os/exec"
	"strings"

	pb "github.com/unbody/darvm/agent/gen"
)

func (rpc *RPC) ResolveIP(ctx context.Context, _ *pb.ResolveIPRequest) (*pb.ResolveIPResponse, error) {
	defaultGateways := map[string]struct{}{}
	if out, err := exec.Command("netstat", "-rn", "-f", "inet").Output(); err == nil {
		for _, line := range strings.Split(string(out), "\n") {
			fields := strings.Fields(line)
			if len(fields) >= 2 && fields[0] == "default" {
				defaultGateways[fields[1]] = struct{}{}
			}
		}
	}

	ifaceAddrs, err := net.InterfaceAddrs()
	if err != nil {
		return nil, fmt.Errorf("failed to retrieve network interface addresses: %w", err)
	}

	var fallback string
	for _, ifaceAddr := range ifaceAddrs {
		ipNet, ok := ifaceAddr.(*net.IPNet)
		if !ok {
			continue
		}

		if ipNet.IP.To4() == nil {
			continue
		}

		if !ipNet.IP.IsGlobalUnicast() {
			continue
		}

		ip := ipNet.IP.String()
		if _, isGateway := defaultGateways[ip]; isGateway {
			if fallback == "" {
				fallback = ip
			}
			continue
		}

		return &pb.ResolveIPResponse{
			Ip: ip,
		}, nil
	}

	if fallback != "" {
		return &pb.ResolveIPResponse{Ip: fallback}, nil
	}

	return nil, fmt.Errorf("cannot resolve VM's IP address")
}
