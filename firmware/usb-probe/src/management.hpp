#pragma once
#include "configuration.hpp"
#include "power.hpp"
#include "inputs.hpp"
#include "quick_overlay.hpp"
#include <functional>
#include <string>
#include <deque>

namespace board {
// Owned by app_main; no USB callbacks perform parsing, storage, or writes.
class Management {
public:
    ConfigStore store;
    Power power;
    std::function<bool()> prepare_change;
    std::function<void()> finish_change;
    std::function<void()> diagnostic_reader;
    void initialize(const char *serial);
    void tick(uint32_t epoch,bool available,bool bluetooth=false);
    void select_manual(unsigned id);
    bool automatic_active() const;
    bool pending() const {return !out_.empty();}
    void trigger_host(unsigned control, Binding binding);
    QuickOverlay quick_overlay; // Main loop owns both producer and transport.
    uint32_t host_drops=0;
    uint32_t errors=0;
    const char *last_error="none";
private:
    const char *serial_="";
    std::string line_,out_;
    struct HostEvent {std::string line; int64_t deadline;};
    std::deque<HostEvent> host_events_;
    uint32_t host_sequence_=0;
    QuickOverlay quick_sent_{};
    uint32_t quick_token_=0, quick_sequence_=0;
    int64_t quick_sent_at_=0;
    bool quick_initial_=false, quick_queued_=false, quick_started_=false;
    InputSnapshot preview_previous_{};
    int64_t preview_deadline_=0, preview_sent_=0, preview_checked_=0;
    uint32_t preview_token_=0, preview_sequence_=0;
    bool available_=false;
    uint32_t epoch_=0;
    uint64_t notified_state_=UINT64_MAX;
    uint32_t auto_session_=0, auto_sequence_=0;
    unsigned auto_layer_=0;
    int64_t auto_deadline_=0;
    void reconcile();
    cJSON *runtime_json() const;
    int64_t last_byte_=0,tx_deadline_=0;
    bool discard_=false, bluetooth_=false;
    size_t write_bytes(const uint8_t *data,size_t size);
    size_t read_bytes(uint8_t *data,size_t size);
    void reject_frame(const char *reason,const std::string &line,int offset=-1);
    size_t request_bytes_=0;
    uint8_t rx_chunk_[256]{};
    size_t rx_size_=0,rx_offset_=0;
    void dispatch(const std::string &line);
    void respond(uint32_t id,cJSON *result,const char *code=nullptr);
};
}
