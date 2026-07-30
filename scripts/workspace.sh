#!/usr/bin/env bash
# Homelab tmux session.
# Usage: ./tmux-homelab.sh    (attaches if the session already exists)

SESSION="kubing"
REPO="$HOME/kubing"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux attach -t "$SESSION"
  exit 0
fi

# Window 1: work
tmux new-session -d -s "$SESSION" -n work -c "$REPO"

# split off the right column (40% width)
tmux split-window -h -p 40 -t "$SESSION:work" -c "$REPO"

# split the right column into top and bottom
tmux split-window -v -p 50 -t "$SESSION:work.1" -c "$REPO"

# pane 1 (top right): k9s, or swap for the watch command below
tmux send-keys -t "$SESSION:work.1" 'k9s' C-m
# tmux send-keys -t "$SESSION:work.1" "watch -n2 'kubectl get pods -A | grep -v Running'" C-m

# pane 2 (bottom right): lazygit
tmux send-keys -t "$SESSION:work.2" 'lazygit' C-m

# Window 2: port-forwards, backgrounded so the shell stays usable
tmux new-window -t "$SESSION" -n fwd -c "$REPO"
tmux send-keys -t "$SESSION:fwd" \
  'kubectl port-forward -n monitoring svc/kps-grafana 3000:80 &' C-m
tmux send-keys -t "$SESSION:fwd" \
  'kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-prometheus 9090 &' C-m

# Window 3: node access
tmux new-window -t "$SESSION" -n node -c "$REPO"

# land on the working window, cursor in the big left pane
tmux select-window -t "$SESSION:work"
tmux select-pane -t "$SESSION:work.0"

tmux attach -t "$SESSION"
