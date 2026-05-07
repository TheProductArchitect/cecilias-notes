import CoreGraphics

public enum Ink {

    public enum Spacing {
        public static let micro: CGFloat = 2
        public static let xs:    CGFloat = 4
        public static let sm:    CGFloat = 8
        public static let md:    CGFloat = 16
        public static let lg:    CGFloat = 24
        public static let xl:    CGFloat = 32
        public static let xxl:   CGFloat = 48
    }

    public enum Radius {
        public static let sm:   CGFloat = 8
        public static let md:   CGFloat = 12
        public static let lg:   CGFloat = 16
        public static let xl:   CGFloat = 24
        public static let full: CGFloat = 9999
    }
}
