import * as React from "react";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

const buttonVariants = cva(
  "inline-flex items-center justify-center rounded-md text-sm font-medium transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 disabled:pointer-events-none disabled:opacity-50",
  { variants: { variant: { default: "bg-primary text-primary-foreground hover:opacity-90", outline: "border border-border bg-background hover:bg-muted" }, size: { default: "h-9 px-4 py-2", sm: "h-8 px-3" } }, defaultVariants: { variant: "default", size: "default" } },
);
/** Local shadcn/ui-style primitive; its source belongs to this repository. */
export function Button({ className, variant, size, ...props }: React.ComponentProps<"button"> & VariantProps<typeof buttonVariants>) {
  return <button data-slot="button" className={cn(buttonVariants({ variant, size, className }))} {...props} />;
}
