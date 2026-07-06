#pragma once

#include "rep_radio_ui_source.h"          // generated from src/radio_ui.rep
#include "logos_ui_plugin_context.h"       // LogosUiPluginContext + modules()

#include <QString>
#include <QTimer>

// radio_ui backend (#40) — universal ui_qml. Thin forwarder: SLOTs → modules().radio_module.*,
// and an async poll mirrors radio_module's JSON state into the PROPs the QML binds to.
// Mutators that spawn subprocesses (startStream→MediaMTX, regenerateOnion→tor) are fire-and-forget
// to avoid the ui-host sync-call deadlock (receiver#20 / basecamp-skills
// universal-modules-sync-call-deadlocks-ui-host).
class RadioUiBackend : public RadioUiSimpleSource, public LogosUiPluginContext
{
    Q_OBJECT
public:
    explicit RadioUiBackend(QObject* parent = nullptr);

public slots:
    QString startStream(QString configJson) override;   // by-value override (rep-slot-byvalue-override)
    QString connectKeycard(QString privHex) override;    // #24 forward the card-derived key → keycardFingerprint
    QString saveIdentityTier(int idx) override;          // #8 persist the identity dropdown selection
    QString stopStream() override;
    QString regenerateKey() override;
    QString regenerateOnion() override;
    QString checkDeps() override;                        // #53 re-run broadcast-helper detection → refresh depsJson

protected:
    void onContextReady() override;                       // modules() live

private:
    void poll();                                          // async getters → PROPs
    void publishDeps();   // #53 detect mediamtx/tor/ffplay/torsocks on PATH → depsJson
    void applyStreamStatus(const QString& json);
    void applyDeliveryStatus(const QString& json);
    void applyStreamCard(const QString& json);

    QTimer* m_poll = nullptr;
};
