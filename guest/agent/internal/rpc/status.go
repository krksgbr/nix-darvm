package rpc

import (
	"context"
	"log"
	"os"
	"os/exec"
	"strings"

	pb "github.com/unbody/darvm/agent/gen"
)

func (rpc *RPC) Status(ctx context.Context, _ *pb.StatusRequest) (*pb.StatusResponse, error) {
	return &pb.StatusResponse{
		Mounts:     gatherMounts(),
		Activation: gatherActivation(),
		Services:   gatherServices(),
	}, nil
}

func gatherMounts() []string {
	out, err := exec.Command("/sbin/mount").Output()
	if err != nil {
		log.Printf("status: mount: %v", err)
		return nil
	}
	var mounts []string
	for _, line := range strings.Split(string(out), "\n") {
		if !strings.Contains(strings.ToLower(line), "virtiofs") {
			continue
		}
		parts := strings.SplitN(line, " on ", 2)
		if len(parts) < 2 {
			continue
		}
		fields := strings.Fields(parts[1])
		if len(fields) > 0 {
			mounts = append(mounts, fields[0])
		}
	}
	return mounts
}

func gatherActivation() string {
	target, err := os.Readlink("/nix/var/nix/profiles/system")
	if err != nil {
		return "none"
	}
	return target
}

func gatherServices() map[string]string {
	out, err := exec.Command("launchctl", "list").Output()
	if err != nil {
		log.Printf("status: launchctl: %v", err)
		return nil
	}
	services := make(map[string]string)
	for _, line := range strings.Split(string(out), "\n") {
		if !strings.Contains(line, "dvm") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		name := fields[2]
		pid := fields[0]
		if pid == "-" {
			services[name] = "stopped"
		} else {
			services[name] = "running"
		}
	}
	return services
}
