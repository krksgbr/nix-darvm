package rpc

import (
	"context"
	"fmt"
	"net"
	"sync/atomic"

	pb "github.com/unbody/darvm/agent/gen"
	"github.com/unbody/darvm/agent/internal/portforward"
	"golang.org/x/sync/errgroup"
	"google.golang.org/grpc"
)

type RPC struct {
	grpcServer          *grpc.Server
	listener            net.Listener
	portForwardListener net.Listener
	portForwardReady    atomic.Bool

	pb.UnimplementedAgentServer
}

func New(listener net.Listener, portForwardListener net.Listener) (*RPC, error) {
	rpc := &RPC{
		grpcServer:          grpc.NewServer(),
		listener:            listener,
		portForwardListener: portForwardListener,
	}
	rpc.portForwardReady.Store(portForwardListener != nil)

	pb.RegisterAgentServer(rpc.grpcServer, rpc)

	return rpc, nil
}

func (rpc *RPC) Run(ctx context.Context) error {
	group, ctx := errgroup.WithContext(ctx)

	group.Go(func() error {
		<-ctx.Done()
		rpc.portForwardReady.Store(false)
		rpc.grpcServer.Stop()

		return nil
	})

	group.Go(func() error {
		if err := rpc.grpcServer.Serve(rpc.listener); err != nil {
			rpc.portForwardReady.Store(false)
			return fmt.Errorf("serve gRPC listener: %w", err)
		}

		return nil
	})

	group.Go(func() error {
		if err := portforward.RunOnListener(ctx, rpc.portForwardListener); err != nil {
			rpc.portForwardReady.Store(false)

			return fmt.Errorf("run port forward listener: %w", err)
		}

		return nil
	})

	if err := group.Wait(); err != nil {
		return fmt.Errorf("serve: %w", err)
	}

	return nil
}
