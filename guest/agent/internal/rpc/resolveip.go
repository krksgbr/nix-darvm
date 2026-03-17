package rpc

import (
	"context"
	"fmt"
	"net"

	pb "github.com/unbody/darvm/agent/gen"
)

func (rpc *RPC) ResolveIP(ctx context.Context, _ *pb.ResolveIPRequest) (*pb.ResolveIPResponse, error) {
	ifaceAddrs, err := net.InterfaceAddrs()
	if err != nil {
		return nil, fmt.Errorf("failed to retrieve network interface addresses: %w", err)
	}

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

		return &pb.ResolveIPResponse{
			Ip: ipNet.IP.String(),
		}, nil
	}

	return nil, fmt.Errorf("cannot resolve VM's IP address")
}
