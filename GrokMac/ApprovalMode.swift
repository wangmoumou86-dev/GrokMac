import Foundation

/// The approval modes shared by the composer pill and Settings. Stored in AppModel.approvalPolicy;
/// "on-request" and "never" are the values older builds saved, so existing settings keep working.
struct ApprovalMode {
    let tag: String
    let title: String
    let detail: String
    let icon: String

    static var all: [ApprovalMode] { [
        ApprovalMode(tag: "readOnly", title: tr("只读", "Read-only"), detail: tr("可以读文件、回答问题，任何修改或运行命令前都先问你", "Reads files and answers; asks before any change or command"), icon: "lock"),
        ApprovalMode(tag: "on-request", title: tr("默认", "Default"), detail: tr("项目内随便读写和运行，越界、联网、危险操作前先问你", "Reads, writes and runs freely in the project; asks before leaving it, going online, or risky actions"), icon: "hand.raised"),
        ApprovalMode(tag: "never", title: tr("完全访问", "Full access"), detail: tr("项目外的文件和联网都不再询问，请谨慎使用", "No prompts for outside files or network. Use with care"), icon: "exclamationmark.triangle"),
    ] }

    static func current(_ tag: String) -> ApprovalMode {
        all.first { $0.tag == tag } ?? all[1]
    }
}
