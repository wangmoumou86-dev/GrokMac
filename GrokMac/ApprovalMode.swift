import Foundation

/// The approval modes shared by the composer pill and Settings. Stored in AppModel.approvalPolicy;
/// "on-request" and "never" are the values older builds saved, so existing settings keep working.
struct ApprovalMode {
    let tag: String
    let title: String
    let detail: String
    let icon: String

    static let all: [ApprovalMode] = [
        ApprovalMode(tag: "readOnly", title: "只读", detail: "可以读文件、回答问题，任何修改或运行命令前都先问你", icon: "lock"),
        ApprovalMode(tag: "on-request", title: "默认", detail: "项目内随便读写和运行，越界、联网、危险操作前先问你", icon: "hand.raised"),
        ApprovalMode(tag: "never", title: "完全访问", detail: "项目外的文件和联网都不再询问，请谨慎使用", icon: "exclamationmark.triangle"),
    ]

    static func current(_ tag: String) -> ApprovalMode {
        all.first { $0.tag == tag } ?? all[1]
    }
}
